import Darwin
import Foundation
import FujiCameraCore
import XCTest

@testable import FujiStudio

@MainActor
final class AutoSaveGatewayTests: XCTestCase {
  private let camera = SavedCamera(
    id: WirelessCameraID(), peripheralID: UUID(), model: .xe3, displayName: "Same name")
  private let otherKey = WirelessProtocolPeerKey(bytes: Data(repeating: 2, count: 32))
  private let selectedKey = WirelessProtocolPeerKey(bytes: Data(repeating: 1, count: 32))

  func testNativeDiscoverySkipsRefusedWildcardCandidateAndAcceptsNextCamera() throws {
    var discoveries = ["192.168.1.28", "192.168.1.32"].map(discovery).makeIterator()
    var notified: [String] = []
    let result = try NativeAutoSaveNetwork.findInvitation(phase: .registration, importer: "FujiStudio-test") {
      try XCTUnwrap(discoveries.next())
    } invite: { source in
      notified.append(source)
      if source == "192.168.1.28" {
        throw NativeAutoSaveNetwork.socketFailure(ECONNREFUSED, discoveredPeer: true)
      }
      return try self.fixtureInvitation()
    }
    XCTAssertEqual(notified, ["192.168.1.28", "192.168.1.32"])
    XCTAssertEqual(result.address, "192.168.1.32")
    XCTAssertEqual(result.cameraName, "Fixture")
  }

  func testNativeDiscoveryReportsLastPeerFailureAtDeadlineAndPreservesTerminalFailures() throws {
    let datagram = discovery("192.168.1.28")
    for terminal in [
      WirelessFailure.timeout(.autoSaveRegistration), .permissionDenied(.localNetwork), .routeUnavailable,
    ] {
      var first = true
      XCTAssertThrowsError(
        try NativeAutoSaveNetwork.findInvitation(phase: .registration, importer: "FujiStudio-test") {
          guard first else { throw terminal }
          first = false
          return datagram
        } invite: { _ in
          throw NativeAutoSaveNetwork.socketFailure(ECONNRESET, discoveredPeer: true)
        }
      ) {
        if terminal == .timeout(.autoSaveRegistration) {
          XCTAssertEqual(($0 as? NativeAutoSaveNetwork.SearchExhausted)?.lastFailure, .connectionLost)
        } else {
          XCTAssertEqual($0 as? WirelessFailure, terminal)
        }
      }
    }
  }

  func testGatewayPreservesCandidateCauseWhenItsDeadlineWinsTheRace() async throws {
    let store = try await cameraStore()
    let clock = ManualWirelessClock()
    let phases = PhaseLog()
    let gateway = makeGateway(store: store, exchange: { phase, _, _, _ in
      await phases.append(phase)
      do {
        try await Task.sleep(for: .seconds(60))
      } catch is CancellationError {
        throw NativeAutoSaveNetwork.SearchExhausted(lastFailure: .autoSavePeerUnreachable)
      }
      throw WirelessFailure.connectionLost
    }, sleep: { try await clock.sleep(for: $0) })
    let setup = Task { try await gateway.register(camera: camera) }
    var waits = clock.scheduled.makeAsyncIterator()
    _ = await waits.next()
    var calls = phases.started.makeAsyncIterator()
    _ = await calls.next()
    await clock.advance(by: .seconds(120))
    await expect(.autoSavePeerUnreachable) { _ = try await setup.value }
  }

  private func discovery(_ source: String) -> NativeAutoSaveNetwork.Datagram {
    let message = "DISCOVER * HTTP/1.1\r\nMX:3\r\nHOST:192.168.1.255:|\r\nDSCADDR:\(source)\r\nSERVICE:PCAUTOSAVE/1.0\r\n"
    return .init(data: Data(message.utf8), source: source)
  }

  private func fixtureInvitation() throws -> AutoSaveCodec.Invitation {
    let text = "REGISTER * HTTP/1.1\r\nHOST:192.168.1.2:51542\r\nDSCNAME:Fixture\r\nDSCMODEL:X-E3\r\n"
    return try XCTUnwrap(AutoSaveCodec.invitation(
      Data(text.utf8), phase: .registration, localAddress: "192.168.1.2"))
  }

  func testAutoSaveAcceptsOnlyRegisteredCameraAndCancellationStopsWait() async throws {
    let store = try await cameraStore()
    let receipt = registration()
    try await store.saveAutoSaveRegistration(receipt, for: camera)
    let good = Session(identity: identity(key: selectedKey))
    let wrong = Session(identity: identity(key: otherKey))
    let newer = Session(identity: identity(key: selectedKey, firmware: "1.33"))
    let absent = Session(identity: identity(key: nil))
    for (session, expected) in [
      (wrong, WirelessFailure.peerMismatch), (newer, .unsupportedFirmware), (absent, .peerMismatch),
    ] {
      let gateway = makeGateway(store: store, makeSession: { _, _, _ in session })
      await expect(expected) { _ = try await gateway.waitForSession(registration: receipt) }
      let closes = await session.closes
      XCTAssertEqual(closes, 1)
    }

    let gateway = makeGateway(store: store, makeSession: { _, _, _ in good })
    let accepted = try await gateway.waitForSession(registration: receipt)
    let peer = try await accepted.open()
    XCTAssertEqual(peer.protocolPeerKey, selectedKey)
    try await accepted.close()

    let suspended = SuspendedSession()
    let lateGateway = makeGateway(store: store, makeSession: { _, _, _ in await suspended.open() })
    let wait = Task { try await lateGateway.waitForSession(registration: receipt) }
    let started = suspended.started
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()
    let cancel = Task { await lateGateway.cancel() }
    for await _ in suspended.cancelled { break }
    await suspended.resume(good)
    await cancel.value
    do {
      _ = try await wait.value
      XCTFail("A late session was adopted after Cancel")
    } catch is CancellationError {
    } catch {
      XCTFail("Unexpected cancellation result")
    }
    let closes = await good.closes
    XCTAssertEqual(closes, 2)
  }

  func testSetupPersistsOnlyAfterIndependentlyBoundFirstTransfer() async throws {
    let store = try await cameraStore()
    let bad = Session(identity: identity(key: otherKey))
    let good = Session(identity: identity(key: selectedKey))
    let phases = PhaseLog()
    let exchange: AutoSaveExchange = { phase, importer, expectedName, _ in
      XCTAssertTrue(importer.hasPrefix("FujiStudio-"))
      XCTAssertEqual(expectedName, phase == .registration ? nil : "same name")
      await phases.append(phase)
      return .init(address: "192.168.1.32", cameraName: "same name")
    }
    let rejected = makeGateway(store: store, exchange: exchange, makeSession: { _, _, _ in bad })
    await expect(.peerMismatch) { _ = try await rejected.register(camera: camera) }
    let missing = try await store.autoSaveRegistration(for: camera.id)
    XCTAssertNil(missing)

    let gateway = makeGateway(store: store, exchange: exchange, makeSession: { _, _, _ in good })
    let camera = self.camera
    let receipt = try await gateway.register(camera: camera) {
      let intermediate = try await store.autoSaveRegistration(for: camera.id)
      XCTAssertNil(intermediate)
    }
    let persisted = try await store.autoSaveRegistration(for: camera.id)
    XCTAssertEqual(persisted, receipt)
    XCTAssertEqual(receipt.peerKey, selectedKey)
    XCTAssertEqual(receipt.cameraID, camera.id)
    XCTAssertFalse(String(reflecting: receipt).contains("FujiStudio-"))
    let recordedPhases = await phases.values
    XCTAssertEqual(recordedPhases, [.registration, .transfer, .registration, .transfer])
    let closeCount = await good.closes
    XCTAssertEqual(closeCount, 1)
  }

  func testWaitRejectsSupersededAndForgottenRegistration() async throws {
    let store = try await cameraStore()
    let former = registration()
    let current = registration()
    try await store.saveAutoSaveRegistration(former, for: camera)
    try await store.saveAutoSaveRegistration(current, for: camera)
    let gateway = makeGateway(store: store, exchange: { _, _, _, _ in
      XCTFail("A stale registration reached the network")
      throw CancellationError()
    })
    await expect(.autoSaveRegistrationRequired) { _ = try await gateway.waitForSession(registration: former) }
    try await store.forget(camera.id)
    await expect(.autoSaveRegistrationRequired) { _ = try await gateway.waitForSession(registration: current) }
  }

  func testEntitlementIdentityAndRouteFailuresAreDistinct() async throws {
    let store = try await cameraStore()
    let unavailable = makeGateway(store: store, entitlementAvailable: false)
    await expect(.autoSaveEntitlementUnavailable) { _ = try await unavailable.register(camera: camera) }
    let unbound = makeGateway(store: store, verifiedIdentity: { _ in nil })
    await expect(.autoSaveIdentityUnavailable) { _ = try await unbound.register(camera: camera) }
    for failure in [WirelessFailure.permissionDenied(.localNetwork), .autoSavePeerUnreachable] {
      let gateway = makeGateway(store: store, exchange: { _, _, _, _ in throw failure })
      await expect(failure) { _ = try await gateway.register(camera: camera) }
    }
    XCTAssertEqual(
      NativeAutoSaveNetwork.socketFailure(EPERM, discoveredPeer: true), .permissionDenied(.localNetwork))
    XCTAssertEqual(NativeAutoSaveNetwork.socketFailure(EHOSTUNREACH, discoveredPeer: true), .autoSavePeerUnreachable)
    XCTAssertEqual(NativeAutoSaveNetwork.socketFailure(EHOSTUNREACH, discoveredPeer: false), .routeUnavailable)
  }

  func testSetupUsesOneDeadlineAcrossRegistrationAndFirstTransfer() async throws {
    let store = try await cameraStore()
    let clock = ManualWirelessClock()
    let phases = PhaseLog()
    let gateway = makeGateway(store: store, exchange: { phase, _, _, deadline in
      await phases.append(phase, deadline: deadline)
      if phase == .transfer { try await Task.sleep(for: .seconds(60)) }
      return .init(address: "192.168.1.32", cameraName: "same name")
    }, sleep: { try await clock.sleep(for: $0) })
    let setup = Task { try await gateway.register(camera: camera) }
    var schedule = clock.scheduled.makeAsyncIterator()
    let delay = await schedule.next()
    XCTAssertEqual(delay, .seconds(120))
    var started = phases.started.makeAsyncIterator()
    for _ in 0..<2 { _ = await started.next() }
    await clock.advance(by: .seconds(120))
    await expect(.timeout(.autoSaveRegistration)) { _ = try await setup.value }
    let deadlines = await phases.deadlines
    XCTAssertEqual(deadlines.count, 2)
    XCTAssertEqual(Set(deadlines).count, 1)
    let saved = try await store.autoSaveRegistration(for: camera.id)
    XCTAssertNil(saved)
  }

  func testDiscoveryDeadlineDuringFirstTransferStillReportsSetupTimeout() async throws {
    let store = try await cameraStore()
    let gateway = makeGateway(store: store, exchange: { phase, _, _, _ in
      if phase == .transfer { throw WirelessFailure.timeout(.autoSaveSession) }
      return .init(address: "192.168.1.32", cameraName: "same name")
    })
    await expect(.timeout(.autoSaveRegistration)) { _ = try await gateway.register(camera: camera) }
  }

  private func cameraStore() async throws -> KeychainCameraStore {
    let namespace = "FujiStudio.Tests.AutoSave.\(UUID())"
    let store = KeychainCameraStore(service: namespace, keychain: ReplayCameraKeychain(service: namespace))
    try await store.save(camera)
    try await store.select(camera.id)
    return store
  }

  private func registration() -> AutoSaveRegistration {
    .init(cameraID: camera.id, peerKey: selectedKey, importer: "FujiStudio-test", cameraName: "same name")
  }

  private func identity(key: WirelessProtocolPeerKey?, firmware: String = "1.32") -> WirelessIdentity {
    .init(cameraID: camera.id, model: .xe3, firmware: firmware, protocolPeerKey: key)
  }

  private func makeGateway(
    store: any AutoSaveRegistrationStore, entitlementAvailable: Bool = true,
    verifiedIdentity: (@Sendable (SavedCamera) async throws -> WirelessProtocolPeerKey?)? = nil,
    exchange: @escaping AutoSaveExchange = { phase, importer, name, _ in
      XCTAssertEqual(phase, .transfer)
      XCTAssertEqual(importer, "FujiStudio-test")
      XCTAssertEqual(name, "same name")
      return .init(address: "192.168.1.32", cameraName: "same name")
    },
    makeSession: @escaping AutoSaveSessionFactory = { _, _, _ in throw WirelessFailure.connectionLost },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) -> NativeAutoSaveGateway {
    let selectedKey = self.selectedKey
    return NativeAutoSaveGateway(
      store: store, entitlementAvailable: entitlementAvailable,
      verifiedIdentity: verifiedIdentity ?? { _ in selectedKey },
      exchange: exchange, makeSession: makeSession, sleep: sleep)
  }

  private func expect(_ failure: WirelessFailure, _ body: () async throws -> Void) async {
    do {
      try await body()
      XCTFail("Expected \(failure)")
    } catch {
      XCTAssertEqual(error as? WirelessFailure, failure)
    }
  }
}

private actor Session: WirelessTransferSession {
  let identity: WirelessIdentity
  private(set) var closes = 0

  init(identity: WirelessIdentity) { self.identity = identity }
  func open() -> WirelessIdentity { identity }
  func close() { closes += 1 }
  func capabilities() throws -> WirelessCapabilities { throw WirelessFailure.connectionLost }
  func enumerate() throws -> AsyncThrowingStream<WirelessInventoryBatch, Error> {
    XCTFail("A handshake must never enumerate")
    throw WirelessFailure.connectionLost
  }
  func thumbnail(_ object: WirelessObjectDescriptor) throws -> Data { throw WirelessFailure.connectionLost }
  func download(
    _ object: WirelessObjectDescriptor, to sink: @escaping @Sendable (Data) async throws -> Void
  ) throws { throw WirelessFailure.connectionLost }
}

private actor SuspendedSession {
  let started: AsyncStream<Void>
  let cancelled: AsyncStream<Void>
  private let start: AsyncStream<Void>.Continuation
  private let cancel: AsyncStream<Void>.Continuation
  private var session: CheckedContinuation<any WirelessTransferSession, Never>?

  init() {
    (started, start) = AsyncStream.makeStream()
    (cancelled, cancel) = AsyncStream.makeStream()
  }

  func open() async -> any WirelessTransferSession {
    await withTaskCancellationHandler {
      await withCheckedContinuation {
        session = $0
        start.yield(())
      }
    } onCancel: { [cancel] in
      cancel.yield(())
    }
  }

  func resume(_ result: any WirelessTransferSession) {
    session?.resume(returning: result)
    session = nil
  }
}

private actor PhaseLog {
  let started: AsyncStream<Void>
  private let progress: AsyncStream<Void>.Continuation
  private(set) var values: [AutoSaveCodec.Phase] = []
  private(set) var deadlines: [ContinuousClock.Instant] = []

  init() { (started, progress) = AsyncStream.makeStream() }

  func append(_ phase: AutoSaveCodec.Phase, deadline: ContinuousClock.Instant? = nil) {
    values.append(phase)
    if let deadline { deadlines.append(deadline) }
    progress.yield(())
  }
}
