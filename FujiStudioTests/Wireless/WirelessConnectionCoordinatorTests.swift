import Foundation
import FujiCameraCore
import XCTest

@testable import FujiStudio

@MainActor
final class WirelessConnectionCoordinatorTests: XCTestCase {
  func testUnauthorizedLaunchMakesNoConnectionAttempt() async throws {
    let fixture = Fixture(authorization: .denied)
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    let blocked = try await state(&updates) { $0.failure == .permissionDenied(.bluetooth) }
    XCTAssertEqual(blocked.selectedCameraID, fixture.first.id)
    XCTAssertEqual(blocked.bluetooth, .unavailable)
    await fixture.coordinator.setActivity(.background)
    XCTAssertTrue(fixture.gateway.calls.isEmpty)
  }

  func testExplicitRetryCanRequestInitialPermission() async throws {
    let fixture = Fixture(authorization: .notDetermined)
    var calls = fixture.gateway.operations.makeAsyncIterator()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    _ = try await state(&updates) { $0.failure == .permissionDenied(.bluetooth) }
    XCTAssertTrue(fixture.gateway.calls.isEmpty)

    await fixture.coordinator.retryBluetooth()
    let attempt = await calls.next(isolation: #isolation)
    XCTAssertEqual(attempt, .reconnect(fixture.first.id, prompt: true))
    fixture.gateway.completeLink()
    _ = try await state(&updates) { $0.bluetooth == .ready }
    XCTAssertEqual(fixture.gateway.wifiActivations, 0)
  }

  func testTransientRetriesBackOffAndAuthFailureStops() async throws {
    let fixture = Fixture()
    var calls = fixture.gateway.operations.makeAsyncIterator()
    var sleeps = fixture.clock.scheduled.makeAsyncIterator()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    let firstAttempt = await calls.next(isolation: #isolation)
    XCTAssertEqual(firstAttempt, .reconnect(fixture.first.id, prompt: false))

    for seconds in [3, 6, 12, 30, 30] {
      fixture.gateway.completeLink(throwing: .timeout(.savedReconnect))
      let delay = await sleeps.next()
      XCTAssertEqual(delay, .seconds(seconds))
      let waiting = try await snapshot(fixture.coordinator)
      XCTAssertEqual(waiting.bluetooth, .waitingForCamera)

      XCTAssertNil(waiting.failure)
      let previousAttempts = fixture.gateway.calls.count
      await fixture.clock.advance(by: .seconds(seconds) - .milliseconds(1))
      XCTAssertEqual(fixture.gateway.calls.count, previousAttempts)
      await fixture.clock.advance(by: .milliseconds(1))
      let nextAttempt = await calls.next(isolation: #isolation)
      XCTAssertEqual(nextAttempt, .reconnect(fixture.first.id, prompt: false))
      _ = try await state(&updates) { $0.bluetooth == .connecting }
    }

    fixture.gateway.completeLink(throwing: .authentication)
    _ = try await state(&updates) { $0.failure == .authentication }
    await fixture.clock.advance(by: .seconds(300))
    await fixture.coordinator.setActivity(.background)
    await fixture.coordinator.setActivity(.active)
    XCTAssertEqual(fixture.gateway.calls.filter { if case .reconnect = $0 { true } else { false } }.count, 6)
    XCTAssertEqual(fixture.gateway.wifiActivations, 0)

    await fixture.coordinator.retryBluetooth()
    // Background may disconnect the native radio after its last attempted operation.
    let retried = await nextReconnect(&calls)
    XCTAssertEqual(retried, .reconnect(fixture.first.id, prompt: true))
    fixture.gateway.completeLink()
    _ = try await state(&updates) { $0.bluetooth == .ready }
  }

  func testTransientPairFailureReconnectsExplicitlySelectedBodyWithBackoff() async throws {
    enum LinkLoss { case authenticationAttempt, authenticatedPairReturn, committedSelection }
    for loss in [LinkLoss.authenticationAttempt, .authenticatedPairReturn, .committedSelection] {
      let fixture = Fixture()
      var calls = fixture.gateway.operations.makeAsyncIterator()
      let states = await fixture.coordinator.states()
      var updates = states.makeAsyncIterator()
      await fixture.coordinator.setActivity(.active)
      _ = await calls.next(isolation: #isolation)
      fixture.gateway.completeLink()
      _ = try await state(&updates) { $0.bluetooth == .ready }
      await fixture.coordinator.startDiscovery()
      _ = await calls.next(isolation: #isolation) // Disconnect the previous link.
      _ = await calls.next(isolation: #isolation)
      let candidate = DiscoveredCamera(
        peripheralID: fixture.second.peripheralID, advertisedModelHint: .xe3, displayName: "X-E3")
      fixture.gateway.discovered([candidate])
      _ = try await state(&updates) { $0.discoveredCameras == [candidate] }
      let heldPair = FixtureBarrier()
      if loss == .authenticatedPairReturn { fixture.gateway.pairReturnBarrier = heldPair }
      if loss == .committedSelection { await fixture.store.suspendSelection(afterCommit: true) }
      await fixture.coordinator.pair(candidate)
      _ = await calls.next(isolation: #isolation)
      switch loss {
      case .authenticationAttempt:
        fixture.gateway.completeLink(throwing: .connectionLost)
      case .authenticatedPairReturn:
        fixture.gateway.completeLink()
        await heldPair.entered()
        fixture.gateway.dropLink(fixture.second.id)
        await fixture.gateway.waitForDisconnectEventDelivery()
        await heldPair.release()
      case .committedSelection:
        var selections = fixture.store.selectionRequests.makeAsyncIterator()
        fixture.gateway.completeLink()
        let committed = await selections.next()
        XCTAssertEqual(committed, fixture.second.id)
        fixture.gateway.dropLink(fixture.second.id)
        await fixture.gateway.waitForDisconnectEventDelivery()
        await fixture.store.resumeSelection()
      }
      let expected = loss == .committedSelection ? fixture.second.id : fixture.first.id
      let scheduled = expectation(description: "selected-camera reconnect is scheduled")
      let delay = Task {
        var sleeps = fixture.clock.scheduled.makeAsyncIterator()
        let delay = await sleeps.next()
        if delay != nil { scheduled.fulfill() }
        return delay
      }
      defer { delay.cancel() }
      guard await XCTWaiter.fulfillment(of: [scheduled], timeout: 2) == .completed else {
        XCTFail("Transient pair loss did not schedule a foreground reconnect")
        continue
      }
      let firstDelay = await delay.value
      XCTAssertEqual(firstDelay, .seconds(3))
      let waiting = await fixture.coordinator.currentState()
      XCTAssertEqual(waiting.bluetooth, .waitingForCamera)
      XCTAssertEqual(waiting.selectedCameraID, expected)
      let attempts = fixture.gateway.calls
      await fixture.clock.advance(by: .milliseconds(2999))
      XCTAssertEqual(fixture.gateway.calls, attempts)
      await fixture.clock.advance(by: .milliseconds(1))
      let next = await nextReconnect(&calls)
      XCTAssertEqual(next, .reconnect(expected, prompt: false))
      fixture.gateway.completeLink()
      await fixture.coordinator.setActivity(.background)
    }
  }

  func testSuccessfulAutomaticRetryResetsBackoffWithoutBackgrounding() async throws {
    let fixture = Fixture()
    var calls = fixture.gateway.operations.makeAsyncIterator()
    var sleeps = fixture.clock.scheduled.makeAsyncIterator()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    _ = await calls.next(isolation: #isolation)
    fixture.gateway.completeLink(throwing: .connectionLost)
    let firstDelay = await sleeps.next()
    XCTAssertEqual(firstDelay, .seconds(3))
    await fixture.clock.advance(by: .seconds(3))
    _ = await calls.next(isolation: #isolation)
    fixture.gateway.completeLink()
    _ = try await state(&updates) { $0.bluetooth == .ready }

    fixture.gateway.dropLink(fixture.first.id)
    let nextDelay = await sleeps.next()
    XCTAssertEqual(nextDelay, .seconds(3))
  }

  func testExplicitWiFiRequestSurvivesInactiveUntilBluetoothIsReady() async throws {
    let fixture = Fixture()
    var calls = fixture.gateway.operations.makeAsyncIterator()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    _ = await calls.next(isolation: #isolation)

    let request = Task { try await fixture.coordinator.prepareWiFiConnection() }
    let waiting = try await state(&updates) { $0.wifi == .waitingForBluetooth }
    await fixture.coordinator.setActivity(.inactive)
    fixture.gateway.completeLink()
    let intent = try await request.value
    XCTAssertEqual(intent.cameraID, fixture.first.id)
    XCTAssertEqual(intent.connectionGeneration, waiting.connectionGeneration)
    let current = await fixture.coordinator.isCurrent(intent)
    XCTAssertTrue(current)
    XCTAssertEqual(fixture.gateway.calls, [.reconnect(fixture.first.id, prompt: false)])
    XCTAssertEqual(fixture.gateway.wifiActivations, 0)
  }

  func testCancelDiscardsWiFiIntentWhileSharedBluetoothBecomesReady() async throws {
    let fixture = Fixture()
    var calls = fixture.gateway.operations.makeAsyncIterator()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    _ = await calls.next(isolation: #isolation)
    let request = Task { try await fixture.coordinator.prepareWiFiConnection() }
    _ = try await state(&updates) { $0.wifi == .waitingForBluetooth }
    await fixture.coordinator.cancelConnection()
    await expectCancellation(request)
    fixture.gateway.completeLink()
    let ready = try await state(&updates) { $0.bluetooth == .ready }
    XCTAssertEqual(ready.wifi, .idle)
    XCTAssertEqual(fixture.gateway.calls, [.reconnect(fixture.first.id, prompt: false)])
  }

  func testExplicitWiFiRequestEndsAfterOneFailedBluetoothAttempt() async throws {
    let fixture = Fixture()
    var calls = fixture.gateway.operations.makeAsyncIterator()
    var sleeps = fixture.clock.scheduled.makeAsyncIterator()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    _ = await calls.next(isolation: #isolation)
    let request = Task { try await fixture.coordinator.prepareWiFiConnection() }
    _ = try await state(&updates) { $0.wifi == .waitingForBluetooth }

    fixture.gateway.completeLink(throwing: .timeout(.savedReconnect))
    do {
      _ = try await request.value
      XCTFail("The WiFi request kept waiting through automatic retries")
    } catch let failure as WirelessFailure {
      XCTAssertEqual(failure, .timeout(.savedReconnect))
    }
    let delay = await sleeps.next()
    XCTAssertEqual(delay, .seconds(3))
    await fixture.clock.advance(by: .seconds(3))
    _ = await calls.next(isolation: #isolation)
    fixture.gateway.completeLink()
    let ready = try await state(&updates) { $0.bluetooth == .ready }
    XCTAssertEqual(ready.wifi, .idle)
    XCTAssertEqual(fixture.gateway.wifiActivations, 0)
  }

  func testBackgroundInvalidatesIntentAndCancelsRetryWithoutRejoiningOnReturn() async throws {
    let fixture = Fixture()
    var calls = fixture.gateway.operations.makeAsyncIterator()
    var sleeps = fixture.clock.scheduled.makeAsyncIterator()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    _ = await calls.next(isolation: #isolation)

    let request = Task { try await fixture.coordinator.prepareWiFiConnection() }
    let waiting = try await state(&updates) { $0.wifi == .waitingForBluetooth }
    fixture.gateway.completeLink(throwing: .connectionLost)
    _ = await request.result
    _ = await sleeps.next()

    await fixture.coordinator.setActivity(.background)
    await fixture.clock.advance(by: .seconds(300))
    XCTAssertEqual(fixture.gateway.calls.filter { if case .reconnect = $0 { true } else { false } }.count, 1)
    await fixture.coordinator.setActivity(.active)
    let foregroundAttempt = await nextReconnect(&calls)
    XCTAssertEqual(foregroundAttempt, .reconnect(fixture.first.id, prompt: false))
    fixture.gateway.completeLink()
    let ready = try await state(&updates) { $0.bluetooth == .ready }
    XCTAssertGreaterThan(ready.connectionGeneration, waiting.connectionGeneration)
    XCTAssertEqual(ready.wifi, .idle)
    XCTAssertEqual(fixture.gateway.wifiActivations, 0)
  }

  func testSelectionChangeDrainsPreviousAuthenticationBeforeStartingAnotherCamera() async throws {
    let fixture = Fixture()
    var calls = fixture.gateway.operations.makeAsyncIterator()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    _ = await calls.next(isolation: #isolation)
    let request = Task { try await fixture.coordinator.prepareWiFiConnection() }
    _ = try await state(&updates) { $0.wifi == .waitingForBluetooth }

    let change = Task { try await fixture.coordinator.select(fixture.second.id) }
    await expectCancellation(request)
    let disconnect = await calls.next(isolation: #isolation)
    XCTAssertEqual(disconnect, .disconnect)
    XCTAssertEqual(fixture.gateway.calls, [.reconnect(fixture.first.id, prompt: false), .disconnect])
    fixture.gateway.completeLink() // A success raced cancellation and remains obsolete.
    try await change.value
    let next = await nextReconnect(&calls)
    XCTAssertEqual(next, .reconnect(fixture.second.id, prompt: false))
    fixture.gateway.completeLink()
    let ready = try await state(&updates) { $0.bluetooth == .ready }
    XCTAssertEqual(ready.selectedCameraID, fixture.second.id)
    XCTAssertEqual(ready.wifi, .idle)
  }

  func testForgetDiscardsAuthenticationAndDoesNotSelectAnotherCamera() async throws {
    let fixture = Fixture()
    var calls = fixture.gateway.operations.makeAsyncIterator()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    _ = await calls.next(isolation: #isolation)

    let forget = Task { try await fixture.coordinator.forget(fixture.first.id) }
    let disconnect = await calls.next(isolation: #isolation)
    XCTAssertEqual(disconnect, .disconnect)
    fixture.gateway.completeLink()
    try await forget.value
    let forgotten = try await state(&updates) { $0.selectedCameraID == nil && $0.savedCameras.count == 1 }
    XCTAssertEqual(forgotten.savedCameras.map(\.id), [fixture.second.id])
    XCTAssertEqual(forgotten.bluetooth, .idle)
    XCTAssertEqual(fixture.gateway.calls, [.reconnect(fixture.first.id, prompt: false), .disconnect])
  }

  func testCancelStopsDiscoveryAndDiscardsLateCandidates() async throws {
    let fixture = Fixture(selected: false)
    var calls = fixture.gateway.operations.makeAsyncIterator()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    await fixture.coordinator.startDiscovery()
    _ = await calls.next(isolation: #isolation)
    let candidate = DiscoveredCamera(
      peripheralID: fixture.first.peripheralID, advertisedModelHint: .xt5, displayName: "X-T5")
    fixture.gateway.discovered([candidate])
    let discovery = try await state(&updates) { $0.discoveredCameras == [candidate] }
    await fixture.coordinator.cancelConnection()
    fixture.gateway.discovered([candidate])
    await fixture.coordinator.pair(candidate)
    let cancelled = try await snapshot(fixture.coordinator)
    XCTAssertGreaterThan(cancelled.connectionGeneration, discovery.connectionGeneration)
    XCTAssertTrue(cancelled.discoveredCameras.isEmpty)
    XCTAssertEqual(cancelled.bluetooth, .idle)
    XCTAssertEqual(fixture.gateway.calls, [.discover, .disconnect])
  }

  func testBackgroundCancelsWiFiWhileBluetoothAuthenticationIsPending() async throws {
    let fixture = Fixture()
    var calls = fixture.gateway.operations.makeAsyncIterator()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    _ = await calls.next(isolation: #isolation)
    let request = Task { try await fixture.coordinator.prepareWiFiConnection() }
    _ = try await state(&updates) { $0.wifi == .waitingForBluetooth }
    let background = Task { await fixture.coordinator.setActivity(.background) }
    await expectCancellation(request)
    let disconnect = await calls.next(isolation: #isolation)
    XCTAssertEqual(disconnect, .disconnect)
    fixture.gateway.completeLink()
    await background.value
    let suspended = try await snapshot(fixture.coordinator)
    XCTAssertEqual(suspended.bluetooth, .idle)
    XCTAssertEqual(suspended.wifi, .idle)
  }


  func testBackgroundDiscardsDiscoveryCallbacksAndLatePairingCannotSelectCamera() async throws {
    let fixture = Fixture(selected: false)
    var calls = fixture.gateway.operations.makeAsyncIterator()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    await fixture.coordinator.startDiscovery()
    let discovery = await calls.next(isolation: #isolation)
    XCTAssertEqual(discovery, .discover)
    let candidate = DiscoveredCamera(
      peripheralID: fixture.first.peripheralID, advertisedModelHint: .xt5, displayName: "X-T5")
    fixture.gateway.discovered([candidate])
    _ = try await state(&updates) { $0.discoveredCameras == [candidate] }
    await fixture.coordinator.pair(candidate)
    let pairing = await calls.next(isolation: #isolation)
    XCTAssertEqual(pairing, .pair(candidate.peripheralID))

    let background = Task { await fixture.coordinator.setActivity(.background) }
    let disconnect = await calls.next(isolation: #isolation)
    XCTAssertEqual(disconnect, .disconnect)
    fixture.gateway.discovered([candidate])
    fixture.gateway.completeLink()
    await background.value
    await fixture.coordinator.setActivity(.active)
    let finished = await fixture.coordinator.states()
    var last = finished.makeAsyncIterator()
    let snapshot = try await state(&last) { _ in true }
    XCTAssertNil(snapshot.selectedCameraID)
    XCTAssertTrue(snapshot.discoveredCameras.isEmpty)
    XCTAssertEqual(snapshot.bluetooth, .idle)
    XCTAssertEqual(fixture.gateway.calls, [.discover, .pair(candidate.peripheralID), .disconnect])
  }

  func testCancelWhilePairSelectionIsQueuedKeepsThePreviousSelection() async throws {
    let fixture = Fixture()
    var calls = fixture.gateway.operations.makeAsyncIterator()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    var selections = fixture.store.selectionRequests.makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    _ = await calls.next(isolation: #isolation)
    fixture.gateway.completeLink()
    _ = try await state(&updates) { $0.bluetooth == .ready }
    await fixture.coordinator.startDiscovery()
    _ = await calls.next(isolation: #isolation) // Disconnect the previous link.
    _ = await calls.next(isolation: #isolation)
    let candidate = DiscoveredCamera(
      peripheralID: fixture.second.peripheralID, advertisedModelHint: .xe3, displayName: "X-E3")
    fixture.gateway.discovered([candidate])
    _ = try await state(&updates) { $0.discoveredCameras == [candidate] }
    await fixture.store.suspendSelection()
    await fixture.coordinator.pair(candidate)
    _ = await calls.next(isolation: #isolation)
    fixture.gateway.completeLink()
    let queued = await selections.next()
    XCTAssertEqual(queued, fixture.second.id)

    let cancel = Task { await fixture.coordinator.cancelConnection() }
    let disconnect = await calls.next(isolation: #isolation)
    XCTAssertEqual(disconnect, .disconnect)
    await fixture.store.resumeSelection()
    await cancel.value
    let selected = await fixture.store.selected()
    XCTAssertEqual(selected, fixture.first.id)
    let attempt = await nextReconnect(&calls)
    XCTAssertEqual(attempt, .reconnect(fixture.first.id, prompt: false))
    fixture.gateway.completeLink()
  }


  func testCancelWhileDiscoveryWaitsForDisconnectPreventsScan() async throws {
    try await verifyPendingDiscoveryIsDiscarded(background: false)
  }

  func testBackgroundAndReturnWhileDiscoveryWaitsForDisconnectPreventsScan() async throws {
    try await verifyPendingDiscoveryIsDiscarded(background: true)
  }

  func testCancellingDiscoveryTaskDuringBluetoothDrainRestoresSavedCameraReconnect() async throws {
    let fixture = Fixture()
    var calls = fixture.gateway.operations.makeAsyncIterator()
    var updates = await fixture.coordinator.states().makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    _ = await calls.next(isolation: #isolation)
    fixture.gateway.completeLink()
    _ = try await state(&updates) { $0.bluetooth == .ready }
    fixture.gateway.pauseDisconnect = true
    let discovery = Task { await fixture.coordinator.startDiscovery() }
    let disconnect = await calls.next(isolation: #isolation)
    XCTAssertEqual(disconnect, .disconnect)
    discovery.cancel()
    fixture.gateway.finishDisconnect()
    await discovery.value
    let current = await fixture.coordinator.currentState()
    XCTAssertEqual(current.bluetooth, .connecting)
    XCTAssertFalse(fixture.gateway.calls.contains(.discover))
  }

  private func verifyPendingDiscoveryIsDiscarded(background: Bool) async throws {
    let fixture = Fixture()
    var calls = fixture.gateway.operations.makeAsyncIterator()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    _ = await calls.next(isolation: #isolation)
    fixture.gateway.completeLink()
    let linked = try await state(&updates) { $0.bluetooth == .ready }
    fixture.gateway.pauseDisconnect = true
    let discovery = Task { await fixture.coordinator.startDiscovery() }
    let disconnect = await calls.next(isolation: #isolation)
    XCTAssertEqual(disconnect, .disconnect)
    let draining = try await snapshot(fixture.coordinator)
    XCTAssertGreaterThan(draining.connectionGeneration, linked.connectionGeneration)

    let (progress, checkpoint) = AsyncStream<Void>.makeStream()
    let invalidation = Task {
      _ = try? await state(&updates) { $0.connectionGeneration > draining.connectionGeneration }
      checkpoint.yield(())
    }
    defer { invalidation.cancel() }
    let interrupted = Task {
      if background {
        await fixture.coordinator.setActivity(.background)
      } else {
        await fixture.coordinator.cancelConnection()
      }
      checkpoint.yield(())
    }
    var milestones = progress.makeAsyncIterator()
    _ = await milestones.next()
    if background { await fixture.coordinator.setActivity(.active) }
    fixture.gateway.finishDisconnect()
    await interrupted.value
    await discovery.value
    let current = try await snapshot(fixture.coordinator)
    XCTAssertNotEqual(current.bluetooth, .discovering)
    XCTAssertFalse(fixture.gateway.calls.contains(.discover))
  }

  func testCancelRestoresPreviouslySelectedCameraAfterPairSelectionAlreadyCommitted() async throws {
    try await verifyCommittedPairSelectionIsReverted(hadSelection: true)
  }

  func testBackgroundRestoresNoSelectionAfterPairSelectionAlreadyCommitted() async throws {
    try await verifyCommittedPairSelectionIsReverted(hadSelection: false)
  }

  func testBackgroundRestoresSelectionWhileKeychainIsLockedAndAcrossRelaunch() async throws {
    let fixture = try PairingPersistenceFixture()
    defer { fixture.removeDefaults() }
    try await fixture.saveCameras(selectPrior: true)
    var calls = fixture.gateway.operations.makeAsyncIterator()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    _ = await calls.next(isolation: #isolation)
    fixture.gateway.completeLink()
    _ = try await state(&updates) { $0.bluetooth == .ready }
    let committed = fixture.store.selectionCommits
    var commits = committed.makeAsyncIterator()
    await fixture.store.suspendNextSelectionCompletion()
    try await beginPair(fixture, calls: &calls, updates: &updates, disconnectFirst: true)
    let candidate = await commits.next()
    XCTAssertEqual(candidate, fixture.candidate.id)

    fixture.keychain.isLocked = true
    let background = Task { await fixture.coordinator.setActivity(.background) }
    let disconnection = await calls.next(isolation: #isolation)
    XCTAssertEqual(disconnection, .disconnect)
    let queriesBeforeRestore = fixture.keychain.copyCount
    await fixture.store.resumeSelectionCompletion()
    await background.value
    XCTAssertEqual(fixture.keychain.copyCount, queriesBeforeRestore)

    fixture.keychain.isLocked = false
    let nativeStore = fixture.makeNativeStore()
    let gateway = ControlledBluetoothGateway(store: nativeStore)
    let relaunched = WirelessConnectionCoordinator(
      bluetooth: gateway, store: nativeStore, authorization: { .allowed })
    await relaunched.setActivity(.active)
    let available = try await snapshot(relaunched)
    XCTAssertEqual(available.selectedCameraID, fixture.prior.id)
    var relaunchedCalls = gateway.operations.makeAsyncIterator()
    let reconnect = await relaunchedCalls.next(isolation: #isolation)
    XCTAssertEqual(reconnect, .reconnect(fixture.prior.id, prompt: false))
    gateway.completeLink()
  }

  func testInFlightSavedStateCannotAdoptSelectionOfCancelledPair() async throws {
    let fixture = try PairingPersistenceFixture()
    defer { fixture.removeDefaults() }
    try await fixture.saveCameras(selectPrior: false)
    let commits = fixture.store.selectionCommits
    var committed = commits.makeAsyncIterator()
    let reads = fixture.store.selectionReads
    var reading = reads.makeAsyncIterator()
    var calls = fixture.gateway.operations.makeAsyncIterator()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    await fixture.store.failNextCameraReads(2)
    await fixture.coordinator.setActivity(.active)
    await fixture.coordinator.startDiscovery()
    _ = await calls.next(isolation: #isolation)
    fixture.gateway.discovered([fixture.advertisement])
    _ = try await state(&updates) { $0.discoveredCameras == [fixture.advertisement] }

    await fixture.coordinator.setActivity(.inactive)
    await fixture.store.suspendNextSelectionRead()
    let reactivation = Task { await fixture.coordinator.setActivity(.active) }
    _ = await reading.next()
    await fixture.store.suspendNextSelectionCompletion()
    await fixture.coordinator.pair(fixture.advertisement)
    _ = await calls.next(isolation: #isolation)
    fixture.gateway.completeLink()
    let candidate = await committed.next()
    XCTAssertEqual(candidate, fixture.candidate.id)

    let cancel = Task { await fixture.coordinator.cancelConnection() }
    let disconnection = await calls.next(isolation: #isolation)
    XCTAssertEqual(disconnection, .disconnect)
    // This read samples the provisional ID while its rollback is still waiting.
    await fixture.store.resumeSelectionRead()
    await reactivation.value
    let duringCleanup = try await snapshot(fixture.coordinator)
    XCTAssertNil(duringCleanup.selectedCameraID)
    await fixture.store.resumeSelectionCompletion()
    await cancel.value
    let durable = try await fixture.makeNativeStore().selected()
    XCTAssertNil(durable)
    let current = try await snapshot(fixture.coordinator)
    XCTAssertNil(current.selectedCameraID)
    XCTAssertFalse(fixture.gateway.calls.contains(.reconnect(fixture.candidate.id, prompt: false)))
  }

  func testSuccessfulPairReconnectsAfterRevokingInFlightSavedStateLoad() async throws {
    let fixture = try PairingPersistenceFixture()
    defer { fixture.removeDefaults() }
    try await fixture.saveCameras(selectPrior: false)
    let reads = fixture.store.selectionReads
    var reading = reads.makeAsyncIterator()
    var calls = fixture.gateway.operations.makeAsyncIterator()
    var sleeps = fixture.clock.scheduled.makeAsyncIterator()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    await fixture.store.failNextCameraReads(2)
    await fixture.coordinator.setActivity(.active)
    await fixture.coordinator.startDiscovery()
    _ = await calls.next(isolation: #isolation)
    fixture.gateway.discovered([fixture.advertisement])
    _ = try await state(&updates) { $0.discoveredCameras == [fixture.advertisement] }
    await fixture.coordinator.setActivity(.inactive)
    await fixture.store.suspendNextSelectionRead()
    let reactivation = Task { await fixture.coordinator.setActivity(.active) }
    _ = await reading.next()

    await fixture.coordinator.pair(fixture.advertisement)
    _ = await calls.next(isolation: #isolation)
    fixture.gateway.completeLink()
    let paired = try await state(&updates) { $0.bluetooth == .ready }
    XCTAssertEqual(paired.selectedCameraID, fixture.candidate.id)
    XCTAssertEqual(Set(paired.savedCameras.map(\.id)), [fixture.prior.id, fixture.candidate.id])
    await fixture.store.resumeSelectionRead()
    await reactivation.value

    fixture.gateway.dropLink(fixture.candidate.id)
    let delay = await sleeps.next()
    XCTAssertEqual(delay, .seconds(3))
    let reconnect = expectation(description: "Retry reconnects the newly selected camera")
    let observation = Task {
      let next = await nextReconnect(&calls)
      if let next {
        XCTAssertEqual(next, .reconnect(fixture.candidate.id, prompt: false))
        fixture.gateway.completeLink()
        reconnect.fulfill()
      }
    }
    defer { observation.cancel() }
    await fixture.clock.advance(by: .seconds(3))
    await fulfillment(of: [reconnect], timeout: 1)
  }

  func testPairDoesNotSelectCandidateWhenPriorSelectionCannotBeValidated() async throws {
    let fixture = try PairingPersistenceFixture()
    defer { fixture.removeDefaults() }
    try await fixture.saveCameras(selectPrior: true)
    await fixture.store.failNextCameraReads(2)
    await fixture.coordinator.setActivity(.active)
    await fixture.store.failNextSelectionRead()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    var calls = fixture.gateway.operations.makeAsyncIterator()
    try await beginPair(fixture, calls: &calls, updates: &updates, disconnectFirst: false)
    let disconnection = await calls.next(isolation: #isolation)
    XCTAssertEqual(disconnection, .disconnect)
    let failed = try await state(&updates) { $0.bluetooth == .unavailable }
    XCTAssertEqual(failed.failure, .unavailableStorage)
    let durable = try await fixture.makeNativeStore().selected()
    XCTAssertEqual(durable, fixture.prior.id)
  }

  private func beginPair(
    _ fixture: PairingPersistenceFixture,
    calls: inout AsyncStream<ControlledBluetoothGateway.Call>.Iterator,
    updates: inout AsyncStream<WirelessConnectionState>.Iterator,
    disconnectFirst: Bool
  ) async throws {
    await fixture.coordinator.startDiscovery()
    if disconnectFirst { _ = await calls.next(isolation: #isolation) }
    _ = await calls.next(isolation: #isolation)
    fixture.gateway.discovered([fixture.advertisement])
    _ = try await state(&updates) { $0.discoveredCameras == [fixture.advertisement] }
    await fixture.coordinator.pair(fixture.advertisement)
    _ = await calls.next(isolation: #isolation)
    fixture.gateway.completeLink()
  }

  private func verifyCommittedPairSelectionIsReverted(hadSelection: Bool) async throws {
    let fixture = Fixture(selected: hadSelection)
    var calls = fixture.gateway.operations.makeAsyncIterator()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    var selections = fixture.store.selectionRequests.makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    if hadSelection {
      _ = await calls.next(isolation: #isolation)
      fixture.gateway.completeLink()
      _ = try await state(&updates) { $0.bluetooth == .ready }
    }
    await fixture.coordinator.startDiscovery()
    if hadSelection { _ = await calls.next(isolation: #isolation) }
    _ = await calls.next(isolation: #isolation)
    let candidate = DiscoveredCamera(
      peripheralID: fixture.second.peripheralID, advertisedModelHint: .xe3, displayName: "X-E3")
    fixture.gateway.discovered([candidate])
    _ = try await state(&updates) { $0.discoveredCameras == [candidate] }
    await fixture.store.suspendSelection(afterCommit: true)
    await fixture.coordinator.pair(candidate)
    _ = await calls.next(isolation: #isolation)
    fixture.gateway.completeLink()
    let committed = await selections.next()
    XCTAssertEqual(committed, fixture.second.id)
    let durable = await fixture.store.selected()
    XCTAssertEqual(durable, fixture.second.id)

    let interrupted = Task {
      if hadSelection {
        await fixture.coordinator.cancelConnection()
      } else {
        await fixture.coordinator.setActivity(.background)
      }
    }
    let disconnect = await calls.next(isolation: #isolation)
    XCTAssertEqual(disconnect, .disconnect)
    await fixture.store.resumeSelection()
    await interrupted.value
    await fixture.coordinator.setActivity(.active)
    let expected = hadSelection ? fixture.first.id : nil
    let selected = await fixture.store.selected()
    XCTAssertEqual(selected, expected)
    let current = try await snapshot(fixture.coordinator)
    XCTAssertEqual(current.selectedCameraID, expected)
    if hadSelection {
      let attempt = await nextReconnect(&calls)
      XCTAssertEqual(attempt, .reconnect(fixture.first.id, prompt: false))
      fixture.gateway.completeLink()
    } else {
      XCTAssertEqual(current.bluetooth, .idle)
    }
  }

  func testFailedSelectionAfterPairRefreshesSavedCredentialsAndKeepsSelection() async throws {
    let fixture = Fixture()
    var calls = fixture.gateway.operations.makeAsyncIterator()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    _ = await calls.next(isolation: #isolation)
    fixture.gateway.completeLink()
    _ = try await state(&updates) { $0.bluetooth == .ready }
    await fixture.coordinator.startDiscovery()
    _ = await calls.next(isolation: #isolation)
    _ = await calls.next(isolation: #isolation)
    let candidate = DiscoveredCamera(
      peripheralID: fixture.second.peripheralID, advertisedModelHint: .xe3, displayName: "X-E3")
    let reference = CameraCredentialReference(cameraID: fixture.second.id, version: UUID())
    fixture.gateway.pairedCamera = SavedCamera(
      id: fixture.second.id, peripheralID: fixture.second.peripheralID, model: .xe3,
      displayName: "X-E3", peerKeyReference: reference)
    fixture.gateway.discovered([candidate])
    _ = try await state(&updates) { $0.discoveredCameras == [candidate] }
    await fixture.store.failNextSelection(.unavailableStorage)
    await fixture.coordinator.pair(candidate)
    _ = await calls.next(isolation: #isolation)
    fixture.gateway.completeLink()
    let disconnected = await calls.next(isolation: #isolation)
    XCTAssertEqual(disconnected, .disconnect)
    let failed = try await state(&updates) { $0.failure == .unavailableStorage }
    XCTAssertEqual(failed.selectedCameraID, fixture.first.id)
    XCTAssertEqual(failed.savedCameras.first { $0.id == fixture.second.id }?.peerKeyReference, reference)
    XCTAssertEqual(failed.bluetooth, .unavailable)
    try await fixture.coordinator.select(fixture.second.id)
    let next = await nextReconnect(&calls)
    XCTAssertEqual(next, .reconnect(fixture.second.id, prompt: false))
    XCTAssertEqual(fixture.gateway.reconnectCamera?.peerKeyReference, reference)
    fixture.gateway.completeLink()
  }

  func testPairingCandidateIsExplicitSelectionAndKeepsItsAuthenticatedLink() async throws {
    let fixture = Fixture(selected: false)
    var calls = fixture.gateway.operations.makeAsyncIterator()
    let states = await fixture.coordinator.states()
    var updates = states.makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    await fixture.coordinator.startDiscovery()
    _ = await calls.next(isolation: #isolation)
    let candidate = DiscoveredCamera(
      peripheralID: fixture.first.peripheralID, advertisedModelHint: .xt5, displayName: "X-T5")
    fixture.gateway.discovered([candidate])
    _ = try await state(&updates) { $0.discoveredCameras == [candidate] }
    await fixture.coordinator.pair(candidate)
    _ = await calls.next(isolation: #isolation)
    fixture.gateway.completeLink()
    let paired = try await state(&updates) { $0.bluetooth == .ready }
    XCTAssertEqual(paired.selectedCameraID, fixture.first.id)
    XCTAssertEqual(Set(paired.savedCameras.map(\.id)), [fixture.first.id, fixture.second.id])
    XCTAssertEqual(fixture.gateway.calls, [.discover, .pair(candidate.peripheralID)])
  }

  func testSelectionIsRejectedUntilTransferPauses() async throws {
    let fixture = Fixture()
    var calls = fixture.gateway.operations.makeAsyncIterator()
    await fixture.coordinator.setActivity(.active)
    _ = await calls.next(isolation: #isolation)
    fixture.gateway.completeLink()
    let intent = try await fixture.coordinator.prepareWiFiConnection()
    try await fixture.coordinator.setTransferActive(true, for: intent)
    do {
      try await fixture.coordinator.select(fixture.second.id)
      XCTFail("Selection changed during a transfer")
    } catch let failure as WirelessFailure {
      XCTAssertEqual(failure, .cameraBusy)
    }
    XCTAssertEqual(fixture.gateway.calls, [.reconnect(fixture.first.id, prompt: false)])
    try await fixture.coordinator.setTransferActive(false, for: intent)
    try await fixture.coordinator.select(fixture.second.id)
    let next = await nextReconnect(&calls)
    XCTAssertEqual(next, .reconnect(fixture.second.id, prompt: false))
    fixture.gateway.completeLink()
  }

  private func snapshot(_ coordinator: WirelessConnectionCoordinator) async throws -> WirelessConnectionState {
    let states = await coordinator.states()
    var updates = states.makeAsyncIterator()
    return try await state(&updates) { _ in true }
  }


  private func state(
    _ updates: inout AsyncStream<WirelessConnectionState>.Iterator,
    where matches: (WirelessConnectionState) -> Bool
  ) async throws -> WirelessConnectionState {
    while let state = await updates.next(isolation: #isolation) {
      if matches(state) { return state }
    }
    throw CancellationError()
  }

  private func nextReconnect(_ calls: inout AsyncStream<ControlledBluetoothGateway.Call>.Iterator) async
    -> ControlledBluetoothGateway.Call?
  {
    while let call = await calls.next(isolation: #isolation) {
      if case .reconnect = call { return call }
    }
    return nil
  }

  private func expectCancellation(_ request: Task<WirelessConnectionIntent, Error>) async {
    if case .failure(let error) = await request.result {
      XCTAssertTrue(error is CancellationError)
    } else {
      XCTFail("A superseded WiFi request completed successfully")
    }
  }

  @MainActor
  private struct Fixture {
    let first = SavedCamera(
      id: WirelessCameraID(), peripheralID: UUID(), model: .xt5, displayName: "X-T5")
    let second = SavedCamera(
      id: WirelessCameraID(), peripheralID: UUID(), model: .xe3, displayName: "X-E3")
    let clock = ManualWirelessClock()
    let store: MemorySavedCameraStore

    let gateway: ControlledBluetoothGateway
    let coordinator: WirelessConnectionCoordinator

    init(authorization: WirelessBluetoothAuthorization = .allowed, selected: Bool = true) {
      self.store = MemorySavedCameraStore(cameras: [first, second], selected: selected ? first.id : nil)
      self.gateway = ControlledBluetoothGateway(store: store)
      self.coordinator = WirelessConnectionCoordinator(
        bluetooth: gateway, store: store, authorization: { authorization }, sleep: clock.sleep)
    }
  }
}

@MainActor
private final class PairingPersistenceFixture {
  let clock = ManualWirelessClock()
  let namespace: String
  let defaults: UserDefaults
  let keychain: ReplayCameraKeychain
  let store: SuspendedSelectionStore
  let gateway: ControlledBluetoothGateway
  let coordinator: WirelessConnectionCoordinator
  let prior = SavedCamera(id: WirelessCameraID(), peripheralID: UUID(), model: .xt5, displayName: "X-T5")
  let candidate = SavedCamera(id: WirelessCameraID(), peripheralID: UUID(), model: .xe3, displayName: "X-E3")

  var advertisement: DiscoveredCamera {
    DiscoveredCamera(
      peripheralID: candidate.peripheralID, advertisedModelHint: candidate.model,
      displayName: candidate.displayName)
  }

  init() throws {
    namespace = "FujiStudio.Tests.PairingPersistence.\(UUID())"
    defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
    keychain = ReplayCameraKeychain(service: namespace)
    store = SuspendedSelectionStore(
      KeychainCameraStore(defaults: defaults, service: namespace, keychain: keychain))
    gateway = ControlledBluetoothGateway(store: store)
    coordinator = WirelessConnectionCoordinator(
      bluetooth: gateway, store: store, authorization: { .allowed }, sleep: clock.sleep)
  }

  func makeNativeStore() -> KeychainCameraStore {
    KeychainCameraStore(defaults: defaults, service: namespace, keychain: keychain)
  }

  func saveCameras(selectPrior: Bool) async throws {
    try await store.save(prior)
    try await store.save(candidate)
    if selectPrior { try await store.select(prior.id) }
  }

  func removeDefaults() { defaults.removePersistentDomain(forName: namespace) }
}

private actor SuspendedSelectionStore: SavedCameraStore {
  let selectionCommits: AsyncStream<WirelessCameraID?>
  private let selectionCommit: AsyncStream<WirelessCameraID?>.Continuation
  let selectionReads: AsyncStream<Void>
  private let selectionRead: AsyncStream<Void>.Continuation
  private let native: KeychainCameraStore
  private var remainingCameraFailures = 0
  private var failSelectionRead = false
  private var holdSelectionCompletion = false
  private var holdSelectionRead = false
  private var completion: CheckedContinuation<Void, Never>?
  private var read: CheckedContinuation<Void, Never>?

  init(_ native: KeychainCameraStore) {
    self.native = native
    (selectionCommits, selectionCommit) = AsyncStream.makeStream()
    (selectionReads, selectionRead) = AsyncStream.makeStream()
  }

  func failNextCameraReads(_ count: Int) { remainingCameraFailures = count }
  func failNextSelectionRead() { failSelectionRead = true }
  func suspendNextSelectionCompletion() { holdSelectionCompletion = true }
  func suspendNextSelectionRead() { holdSelectionRead = true }

  func resumeSelectionCompletion() {
    completion?.resume()
    completion = nil
  }

  func resumeSelectionRead() {
    read?.resume()
    read = nil
  }

  func cameras() async throws -> [SavedCamera] {
    if remainingCameraFailures > 0 {
      remainingCameraFailures -= 1
      throw WirelessFailure.unavailableStorage
    }
    return try await native.cameras()
  }

  func selected() async throws -> WirelessCameraID? {
    if failSelectionRead {
      failSelectionRead = false
      throw WirelessFailure.unavailableStorage
    }
    if holdSelectionRead {
      holdSelectionRead = false
      await withCheckedContinuation { continuation in
        read = continuation
        selectionRead.yield(())
      }
    }
    return try await native.selected()
  }

  func save(_ camera: SavedCamera) async throws { try await native.save(camera) }

  func select(_ id: WirelessCameraID?) async throws {
    try await native.select(id)
    if holdSelectionCompletion {
      holdSelectionCompletion = false
      await withCheckedContinuation { continuation in
        completion = continuation
        selectionCommit.yield(id)
      }
    }
  }

  func forget(_ id: WirelessCameraID) async throws { try await native.forget(id) }

  func restoreSelection(_ previous: WirelessCameraID?, replacing candidate: WirelessCameraID) async {
    await native.restoreSelection(previous, replacing: candidate)
  }
}

private actor MemorySavedCameraStore: SavedCameraStore {
  private var saved: [SavedCamera]
  private var selection: WirelessCameraID?
  private enum SelectionPause { case beforeCommit, afterCommit }

  private var selectionPause: SelectionPause?
  private var selectionFailure: WirelessFailure?
  private var selectionWaiter: CheckedContinuation<Void, Never>?
  private let selectionRequest: AsyncStream<WirelessCameraID>.Continuation
  let selectionRequests: AsyncStream<WirelessCameraID>


  init(cameras: [SavedCamera], selected: WirelessCameraID?) {
    saved = cameras
    selection = selected
    (selectionRequests, selectionRequest) = AsyncStream.makeStream()

  }

  func cameras() -> [SavedCamera] { saved }
  func selected() -> WirelessCameraID? { selection }

  func save(_ camera: SavedCamera) {
    saved.removeAll { $0.id == camera.id }
    saved.append(camera)
  }

  func suspendSelection(afterCommit: Bool = false) {
    selectionPause = afterCommit ? .afterCommit : .beforeCommit
  }

  func failNextSelection(_ failure: WirelessFailure) { selectionFailure = failure }

  func resumeSelection() {
    selectionWaiter?.resume()
    selectionWaiter = nil
  }

  func select(_ id: WirelessCameraID?) async throws {
    if let selectionFailure {
      self.selectionFailure = nil
      throw selectionFailure
    }
    if let id, selectionPause == .beforeCommit { await pauseSelection(id) }
    try Task.checkCancellation()
    if let id, !saved.contains(where: { $0.id == id }) { throw WirelessFailure.peerMismatch }
    selection = id
    if let id, selectionPause == .afterCommit { await pauseSelection(id) }
  }

  private func pauseSelection(_ id: WirelessCameraID) async {
    selectionPause = nil
    await withCheckedContinuation { waiter in
      selectionWaiter = waiter
      selectionRequest.yield(id)
    }
  }

  func restoreSelection(_ previous: WirelessCameraID?, replacing candidate: WirelessCameraID) {
    if selection == candidate { selection = previous }
  }

  func forget(_ id: WirelessCameraID) {
    saved.removeAll { $0.id == id }
    if selection == id { selection = nil }
  }
}

@MainActor
private final class ControlledBluetoothGateway: BluetoothGateway {
  enum Call: Equatable {
    case discover
    case pair(UUID)
    case reconnect(WirelessCameraID, prompt: Bool)
    case disconnect
  }

  let operations: AsyncStream<Call>
  private(set) var calls: [Call] = []
  private(set) var wifiActivations = 0
  private(set) var reconnectCamera: SavedCamera?
  var pauseDisconnect = false
  var pairedCamera: SavedCamera?
  var pairReturnBarrier: FixtureBarrier?
  private let store: any SavedCameraStore
  private let operation: AsyncStream<Call>.Continuation
  private var event: AsyncStream<BluetoothGatewayEvent>.Continuation?
  private var eventCursor: BluetoothEventCursor?
  private var discovery: AsyncThrowingStream<[DiscoveredCamera], Error>.Continuation?
  private var link: CheckedContinuation<Void, Error>?
  private var disconnectWaiter: CheckedContinuation<Void, Never>?
  private var camera: SavedCamera?

  init(store: any SavedCameraStore) {
    self.store = store
    (operations, operation) = AsyncStream.makeStream()
  }

  func discover() async throws -> AsyncThrowingStream<[DiscoveredCamera], Error> {
    let (stream, continuation) = AsyncThrowingStream<[DiscoveredCamera], Error>.makeStream()
    discovery = continuation
    record(.discover)
    return stream
  }

  func discovered(_ candidates: [DiscoveredCamera]) { discovery?.yield(candidates) }

  func pair(_ candidate: DiscoveredCamera) async throws -> SavedCamera {
    let cameras = try await store.cameras()
    let saved = try XCTUnwrap(pairedCamera ?? cameras.first { $0.peripheralID == candidate.peripheralID })
    try await connect(saved, as: .pair(candidate.peripheralID))
    try await store.save(saved)
    await pairReturnBarrier?.wait()
    return saved
  }

  func reconnect(_ saved: SavedCamera, allowPermissionPrompt: Bool) async throws {
    reconnectCamera = saved
    try await connect(saved, as: .reconnect(saved.id, prompt: allowPermissionPrompt))
  }

  func identity(for id: WirelessCameraID) async throws -> WirelessIdentity {
    guard let camera, camera.id == id else { throw WirelessFailure.connectionLost }
    return WirelessIdentity(cameraID: id, model: camera.model, firmware: nil)
  }

  func activateWiFi(for id: WirelessCameraID) async throws -> CameraNetwork {
    wifiActivations += 1
    throw WirelessFailure.connectionLost
  }

  func events() async -> AsyncStream<BluetoothGatewayEvent> {
    let (stream, continuation) = AsyncStream<BluetoothGatewayEvent>.makeStream()
    event = continuation
    let cursor = BluetoothEventCursor(stream)
    eventCursor = cursor
    return AsyncStream(unfolding: { await cursor.next() })
  }

  func disconnect() async {
    discovery?.finish()
    record(.disconnect)
    if link != nil || pauseDisconnect {
      await withCheckedContinuation { disconnectWaiter = $0 }
    }
    camera = nil
  }

  func finishDisconnect() {
    pauseDisconnect = false
    disconnectWaiter?.resume()
    disconnectWaiter = nil
  }

  func completeLink(throwing error: WirelessFailure? = nil) {
    guard let link else {
      XCTFail("There was no pending authentication attempt")
      return
    }
    self.link = nil
    if let error { link.resume(throwing: error) } else { link.resume() }
    finishDisconnect()
  }

  func dropLink(_ id: WirelessCameraID) {
    camera = nil
    event?.yield(.disconnected(id, .connectionLost))
  }

  func waitForDisconnectEventDelivery() async {
    guard let eventCursor else { XCTFail("There is no Bluetooth event subscription"); return }
    await eventCursor.waitForConsumption()
  }

  private func connect(_ saved: SavedCamera, as call: Call) async throws {
    precondition(link == nil, "Native link attempts overlapped")
    try await withCheckedThrowingContinuation { continuation in
      link = continuation
      record(call)
    }
    camera = saved
  }

  private func record(_ call: Call) {
    calls.append(call)
    operation.yield(call)
  }
}

/// The coordinator's listener requests the next event only after processing the last one.
@MainActor private final class BluetoothEventCursor {
  private var iterator: AsyncStream<BluetoothGatewayEvent>.Iterator
  private var returnedEvent = false
  private let consumed: AsyncStream<Void>
  private let consumption: AsyncStream<Void>.Continuation

  init(_ source: AsyncStream<BluetoothGatewayEvent>) {
    iterator = source.makeAsyncIterator()
    (consumed, consumption) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }

  func next() async -> BluetoothGatewayEvent? {
    if returnedEvent { consumption.yield() }
    var iterator = self.iterator
    let event = await iterator.next(isolation: #isolation)
    self.iterator = iterator
    returnedEvent = event != nil
    return event
  }

  func waitForConsumption() async {
    var iterator = consumed.makeAsyncIterator()
    _ = await iterator.next(isolation: #isolation)
  }
}
