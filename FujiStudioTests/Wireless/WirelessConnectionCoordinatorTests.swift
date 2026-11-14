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
    fixture.gateway.dropLink(fixture.first.id)
    let delayAfterSuccess = await sleeps.next()
    XCTAssertEqual(delayAfterSuccess, .seconds(3))
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

private actor MemorySavedCameraStore: SavedCameraStore {
  private var saved: [SavedCamera]
  private var selection: WirelessCameraID?
  private var pausesSelection = false
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

  func suspendSelection() { pausesSelection = true }

  func resumeSelection() {
    pausesSelection = false
    selectionWaiter?.resume()
    selectionWaiter = nil
  }

  func select(_ id: WirelessCameraID) async throws {
    if pausesSelection {
      await withCheckedContinuation { waiter in
        selectionWaiter = waiter
        selectionRequest.yield(id)
      }
    }

    try Task.checkCancellation()
    guard saved.contains(where: { $0.id == id }) else { throw WirelessFailure.peerMismatch }
    selection = id
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
  private let store: MemorySavedCameraStore
  private let operation: AsyncStream<Call>.Continuation
  private var event: AsyncStream<BluetoothGatewayEvent>.Continuation?
  private var discovery: AsyncThrowingStream<[DiscoveredCamera], Error>.Continuation?
  private var link: CheckedContinuation<Void, Error>?
  private var disconnectWaiter: CheckedContinuation<Void, Never>?
  private var camera: SavedCamera?

  init(store: MemorySavedCameraStore) {
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
    let cameras = await store.cameras()
    let saved = try XCTUnwrap(cameras.first { $0.peripheralID == candidate.peripheralID })
    try await connect(saved, as: .pair(candidate.peripheralID))
    await store.save(saved)
    return saved
  }

  func reconnect(_ saved: SavedCamera, allowPermissionPrompt: Bool) async throws {
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
    return stream
  }

  func disconnect() async {
    discovery?.finish()
    record(.disconnect)
    if link != nil {
      await withCheckedContinuation { disconnectWaiter = $0 }
    }
    camera = nil
  }

  func completeLink(throwing error: WirelessFailure? = nil) {
    guard let link else {
      XCTFail("There was no pending authentication attempt")
      return
    }
    self.link = nil
    if let error { link.resume(throwing: error) } else { link.resume() }
    disconnectWaiter?.resume()
    disconnectWaiter = nil
  }

  func dropLink(_ id: WirelessCameraID) {
    camera = nil
    event?.yield(.disconnected(id, .connectionLost))
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
