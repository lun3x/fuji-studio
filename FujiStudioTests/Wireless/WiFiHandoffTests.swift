import Foundation
import FujiCameraCore
import XCTest

@testable import FujiStudio

@MainActor
final class WiFiHandoffTests: XCTestCase {
  func testOnlyAdmittedPeerWithUsableInventoryBecomesReady() async throws {
    let fixture = Fixture()
    await fixture.start()
    await fixture.coordinator.connectWiFi()
    let ready = await snapshot(fixture.coordinator)
    XCTAssertEqual(ready.wifi, .ready)
    _ = try await fixture.coordinator.transferSession()
    XCTAssertEqual(fixture.log.events, [
      "authenticated", "ownership", "BLE identity", "credentials", "camera ready",
      "native join", "verify association", "allocate socket", "PTP identity",
      "verify association", "inventory",
    ])

    await fixture.coordinator.disconnectWiFi()
    XCTAssertEqual(Array(fixture.log.events.suffix(3)), ["close socket", "leave", "release ownership"])
    await expectNoSession(fixture.coordinator)
  }

  func testFailuresStopAtTheStageThatOwnsThem() async {
    for (failure, phase, last) in [
      (WirelessFailure.malformedData, WirelessWiFiPhase.activatingCamera, "credentials"),
      (.timeout(.wifiReadiness), .activatingCamera, "credentials"),
      (.permissionDenied(.wifiJoin), .joiningNetwork, "native join"),
      (.timeout(.joinResult), .joiningNetwork, "native join"),
      (.timeout(.tcpSetup), .openingSession, "PTP identity"),
      (.peerMismatch, .checkingFirmware, "PTP identity"),
      (.unsupportedFirmware, .checkingFirmware, "verify association"),
      (.unavailableStorage, .loadingInventory, "inventory"),
    ] {
      let fixture = Fixture(failure: failure)
      await fixture.start()
      await fixture.coordinator.connectWiFi()
      let state = await snapshot(fixture.coordinator)
      XCTAssertEqual(state.wifi, .idle)
      XCTAssertEqual(state.wifiFailure, failure)
      XCTAssertEqual(state.wifiFailurePhase, phase)
      await expectNoSession(fixture.coordinator)
      XCTAssertEqual(
        fixture.log.events.filter { !["close socket", "leave", "release ownership"].contains($0) }.last,
        last)
    }
  }

  func testCancelledJoinCannotAdoptLateCompletion() async {
    for owned in [true, false] {
      let fixture = Fixture()
      fixture.gateway.holdJoin = true
      fixture.gateway.owns = owned
      await fixture.start()
      let updates = await fixture.coordinator.states()
      var iterator = updates.makeAsyncIterator()
      let connect = Task { await fixture.coordinator.connectWiFi() }
      await fixture.gateway.joinEntered()
      await expectNoSession(fixture.coordinator)
      let cancel = Task { await fixture.coordinator.cancelConnection() }
      while let state = await iterator.next(), state.wifi != .disconnecting {}
      fixture.gateway.finishJoin()
      await connect.value
      await cancel.value

      XCTAssertFalse(fixture.log.events.contains("allocate socket"))
      XCTAssertEqual(fixture.gateway.removedSSIDs, owned ? ["selected"] : [])
      XCTAssertFalse(fixture.gateway.removedSSIDs.contains("preexisting"))
      XCTAssertEqual(Array(fixture.log.events.suffix(2)), ["leave", "release ownership"])
      await expectNoSession(fixture.coordinator)
    }
  }

  func testBluetoothLossAfterCameraReadinessDoesNotInvalidatePTP() async throws {
    let fixture = Fixture()
    fixture.gateway.holdJoin = true
    await fixture.start()
    let connect = Task { await fixture.coordinator.connectWiFi() }
    await fixture.gateway.joinEntered()
    fixture.bluetooth.drop()
    let stream = await fixture.coordinator.states()
    var states = stream.makeAsyncIterator()
    while let state = await states.next(), state.bluetooth == .ready {}
    fixture.gateway.finishJoin()
    await connect.value
    _ = try await fixture.coordinator.transferSession()
    XCTAssertEqual(fixture.log.events.filter { $0 == "authenticated" }.count, 1)
    await fixture.coordinator.setActivity(.background)
  }

  func testNativeJoinSnapshotsOwnershipAndValidatesActualSecureAssociation() async throws {
    for (preexisting, result, expectedOwner) in [
      (false, HotspotApplyResult.applied, true),
      (true, .applied, false),
      (false, .alreadyAssociated, false),
    ] {
      let driver = HotspotFixture()
      driver.existing = preexisting ? ["selected"] : []
      driver.result = result
      let gateway = NativeWiFiJoinGateway(credentials: PasswordFixture(), driver: driver)
      let joined = try await gateway.join(network())
      XCTAssertEqual(joined.ownsTemporaryConfiguration, expectedOwner)
      XCTAssertEqual(driver.appliedWithJoinOnce, preexisting ? nil : true)
      try await gateway.verify(joined)
      driver.association = .init(ssid: "another", isSecure: true)
      do {
        try await gateway.verify(joined)
        XCTFail("Another network was accepted")
      } catch { XCTAssertEqual(error as? WirelessFailure, .routeUnavailable) }
      await gateway.leave(joined)
      await gateway.leave(joined)
      XCTAssertEqual(driver.removed, expectedOwner ? ["selected"] : [])
    }
  }

  func testNativeLateApplyAfterTimeoutRemovesOnlyItsOwnConfiguration() async {
    for result in [HotspotApplyResult.applied, .alreadyAssociated] {
      let driver = HotspotFixture()
      driver.holdApply = true
      driver.result = result
      let clock = ManualWirelessClock()
      var sleeps = clock.scheduled.makeAsyncIterator()
      let gateway = NativeWiFiJoinGateway(
        credentials: PasswordFixture(), driver: driver, sleep: { try await clock.sleep(for: $0) })
      let join = Task { try await gateway.join(network()) }
      await driver.applyEntered()
      let limit = await sleeps.next()
      XCTAssertEqual(limit, .seconds(120))
      await clock.advance(by: .seconds(120))
      do {
        _ = try await join.value
        XCTFail("The native prompt exceeded the app deadline")
      } catch { XCTAssertEqual(error as? WirelessFailure, .timeout(.joinResult)) }
      driver.finishApply()
      await gateway.drainPendingJoin()
      XCTAssertEqual(driver.removed, result == .applied ? ["selected"] : [])
    }
  }

  #if DEBUG
  func testWirelessProbeNeedsExclusiveExplicitLaunchFlag() {
    XCTAssertEqual(FixtureEnvironment.route(arguments: ["FujiStudio"], unitHost: false), .live)
    XCTAssertEqual(
      FixtureEnvironment.route(arguments: ["FujiStudio", "--wireless-protocol-probe"], unitHost: false),
      .wirelessProbe)
    XCTAssertEqual(
      FixtureEnvironment.route(
        arguments: ["FujiStudio", "--wireless-protocol-probe", "--ui-fixtures"], unitHost: false), .invalid)
    XCTAssertEqual(
      FixtureEnvironment.route(
        arguments: ["FujiStudio", "--wireless-protocol-probe", "--xt5-read-only-probe"], unitHost: false), .invalid)
    XCTAssertEqual(
      FixtureEnvironment.route(
        arguments: ["FujiStudio", "--wireless-probe-bluetooth-only"], unitHost: false), .invalid)
    XCTAssertEqual(
      FixtureEnvironment.route(arguments: ["FujiStudio", "--wireless-protocol-probe"], unitHost: true),
      .unitHost)
  }
  #endif

  private func snapshot(_ coordinator: WirelessConnectionCoordinator) async -> WirelessConnectionState {
    let stream = await coordinator.states()
    var iterator = stream.makeAsyncIterator()
    return await iterator.next()!
  }

  private func expectNoSession(_ coordinator: WirelessConnectionCoordinator) async {
    do {
      _ = try await coordinator.transferSession()
      XCTFail("An unusable transfer session escaped")
    } catch {}
  }
}

@MainActor
private final class Fixture {
  let id = WirelessCameraID()
  let log = HandoffLog()
  let bluetooth: HandoffBluetooth
  let gateway: HandoffWiFi
  let coordinator: WirelessConnectionCoordinator

  init(failure: WirelessFailure? = nil) {
    let camera = SavedCamera(id: id, peripheralID: UUID(), model: .xt5, displayName: "Fixture")
    let bluetooth = HandoffBluetooth(id: id, log: log, failure: failure)
    let gateway = HandoffWiFi(log: log, failure: failure)
    let log = self.log
    self.bluetooth = bluetooth
    self.gateway = gateway
    coordinator = WirelessConnectionCoordinator(
      bluetooth: bluetooth, store: HandoffStore(camera: camera),
      authorization: { .allowed }, wifi: gateway, ownership: HandoffOwner(log: log),
      sessionFactory: { identity, _ in
        await log.record("allocate socket")
        return HandoffSession(identity: identity, log: log, failure: failure)
      })
  }

  func start() async {
    await coordinator.setActivity(.active)
    let stream = await coordinator.states()
    var iterator = stream.makeAsyncIterator()
    while let state = await iterator.next(), state.bluetooth != .ready {}
  }
}

@MainActor
private final class HandoffLog {
  private(set) var events: [String] = []
  func record(_ event: String) { events.append(event) }
}

@MainActor
private final class HandoffBluetooth: BluetoothGateway {
  let id: WirelessCameraID
  let log: HandoffLog
  let failure: WirelessFailure?
  let notifications = AsyncStream<BluetoothGatewayEvent>.makeStream()

  init(id: WirelessCameraID, log: HandoffLog, failure: WirelessFailure?) {
    self.id = id
    self.log = log
    self.failure = failure
  }

  func discover() async throws -> AsyncThrowingStream<[DiscoveredCamera], any Error> {
    throw WirelessFailure.unsupportedProtocol
  }
  func pair(_ camera: DiscoveredCamera) async throws -> SavedCamera {
    throw WirelessFailure.unsupportedProtocol
  }
  func reconnect(_ camera: SavedCamera, allowPermissionPrompt: Bool) async throws { log.record("authenticated") }
  func identity(for id: WirelessCameraID) async throws -> WirelessIdentity {
    log.record("BLE identity")
    return .init(cameraID: id, model: .xt5, firmware: "4.32")
  }
  func activateWiFi(for id: WirelessCameraID) async throws -> CameraNetwork {
    log.record("credentials")
    if let failure, [.malformedData, .timeout(.wifiReadiness)].contains(failure) { throw failure }
    log.record("camera ready")
    return network(id: id)
  }
  func events() async -> AsyncStream<BluetoothGatewayEvent> { notifications.stream }
  func disconnect() async {}
  func drop() { notifications.continuation.yield(.disconnected(id, .connectionLost)) }
}

private struct HandoffStore: SavedCameraStore {
  let camera: SavedCamera
  func cameras() async throws -> [SavedCamera] { [camera] }
  func selected() async throws -> WirelessCameraID? { camera.id }
  func save(_ camera: SavedCamera) async throws {}
  func select(_ id: WirelessCameraID?) async throws {}
  func restoreSelection(_ previous: WirelessCameraID?, replacing candidate: WirelessCameraID) async {}
  func forget(_ id: WirelessCameraID) async throws {}
}

@MainActor
private final class HandoffWiFi: WiFiJoinGateway {
  let log: HandoffLog
  let failure: WirelessFailure?
  var holdJoin = false
  var owns = true
  var removedSSIDs: [String] = []
  private var started = false
  private var gate: CheckedContinuation<Void, Never>?
  private var entered: CheckedContinuation<Void, Never>?

  init(log: HandoffLog, failure: WirelessFailure?) {
    self.log = log
    self.failure = failure
  }
  func join(_ network: CameraNetwork) async throws -> JoinedCameraNetwork {
    log.record("native join")
    started = true
    entered?.resume()
    entered = nil
    if holdJoin { await withCheckedContinuation { gate = $0 } }
    if let failure, [.timeout(.joinResult), .permissionDenied(.wifiJoin)].contains(failure) { throw failure }
    return .init(ssid: network.ssid, ownsTemporaryConfiguration: owns)
  }
  func verify(_ network: JoinedCameraNetwork) async throws { log.record("verify association") }
  func leave(_ network: JoinedCameraNetwork) async {
    log.record("leave")
    if network.ownsTemporaryConfiguration { removedSSIDs.append(network.ssid) }
  }
  func drainPendingJoin() async {}
  func joinEntered() async {
    if !started { await withCheckedContinuation { entered = $0 } }
  }
  func finishJoin() { gate?.resume(); gate = nil }
}

private struct HandoffOwner: WirelessCameraOwnershipGateway {
  let log: HandoffLog
  func acquireWireless() async throws -> CameraUseLease {
    await log.record("ownership")
    return .init()
  }
  func releaseWireless(_ lease: CameraUseLease) async { await log.record("release ownership") }
}

private struct HandoffSession: WirelessTransferSession {
  let identity: WirelessIdentity
  let log: HandoffLog
  let failure: WirelessFailure?

  func open() async throws -> WirelessIdentity {
    await log.record("PTP identity")
    if failure == .timeout(.tcpSetup) { throw WirelessFailure.timeout(.tcpSetup) }
    if failure == .peerMismatch { return .init(cameraID: .init(), model: .xt5, firmware: "4.32") }
    if failure == .unsupportedFirmware {
      return .init(cameraID: identity.cameraID, model: .xt5, firmware: "4.31")
    }
    return identity
  }
  func capabilities() async throws -> WirelessCapabilities {
    .init(mode: .xApp, rawExposure: .unknown, storageIDs: [1], originalSizeVerified: false, evidenceID: "test")
  }
  func enumerate() async throws -> AsyncThrowingStream<WirelessInventoryBatch, Error> {
    await log.record("inventory")
    let status: WirelessStorageInventory.Completeness = failure == .unavailableStorage ? .unavailable : .complete
    return AsyncThrowingStream {
      $0.yield(.init(objects: [], storageChanges: [1: status]))
      $0.finish()
    }
  }
  func thumbnail(_ object: WirelessObjectDescriptor) async throws -> Data { Data() }
  func download(_ object: WirelessObjectDescriptor, to sink: @escaping @Sendable (Data) async throws -> Void) async throws {}
  func close() async throws { await log.record("close socket") }
}

private func network(id: WirelessCameraID = .init()) -> CameraNetwork {
  .init(ssid: "selected", security: .wpaPersonal, credential: .init(cameraID: id, version: UUID()), isHidden: true)
}

private struct PasswordFixture: CameraNetworkCredentialProvider {
  func password(for reference: CameraCredentialReference) async throws -> String { "private-fixture" }
}

@MainActor
private final class HotspotFixture: HotspotConfigurationDriver {
  var existing: [String] = []
  var result = HotspotApplyResult.applied
  var association: HotspotAssociation? = .init(ssid: "selected", isSecure: true)
  var removed: [String] = []
  var appliedWithJoinOnce: Bool?
  var holdApply = false
  private var applying: CheckedContinuation<Void, Never>?
  private var entered: CheckedContinuation<Void, Never>?

  func configuredSSIDs() async -> [String] { existing }
  func apply(_ network: CameraNetwork, password: String, joinOnce: Bool) async throws -> HotspotApplyResult {
    appliedWithJoinOnce = joinOnce
    entered?.resume()
    entered = nil
    if holdApply { await withCheckedContinuation { applying = $0 } }
    return result
  }
  func currentAssociation() async -> HotspotAssociation? { association }
  func removeConfiguration(forSSID ssid: String) { removed.append(ssid) }
  func applyEntered() async {
    if appliedWithJoinOnce == nil { await withCheckedContinuation { entered = $0 } }
  }
  func finishApply() { applying?.resume(); applying = nil }
}
