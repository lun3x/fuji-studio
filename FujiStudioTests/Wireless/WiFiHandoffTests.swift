import Foundation
import FujiCameraCore
import XCTest

@testable import FujiStudio

@MainActor
final class WiFiHandoffTests: XCTestCase {
  func testManualHandoffRetainsCredentialsAcrossSettingsAndOpensGallery() async throws {
    let route = HandoffBarrier()
    let fixture = Fixture(manualRoute: route)
    await fixture.start()
    let connecting = Task { await fixture.coordinator.connectWiFi() }
    await route.entered()
    let prompt = await snapshot(fixture.coordinator)
    let network = try XCTUnwrap(prompt.manualNetwork)
    let password = try await fixture.coordinator.handoffPassword(for: network)
    XCTAssertEqual(password, "private-fixture")
    await fixture.coordinator.setActivity(.background)
    let background = await snapshot(fixture.coordinator)
    XCTAssertEqual(background.manualNetwork, network)
    XCTAssertTrue(background.hasTransferLease)
    await fixture.coordinator.setActivity(.active)
    await route.release()
    await connecting.value
    let connected = await snapshot(fixture.coordinator)
    XCTAssertEqual(connected.wifi, .ready)
    XCTAssertNil(connected.manualNetwork)
    XCTAssertFalse(fixture.log.events.contains("native join"))
    await fixture.coordinator.disconnectWiFi()
  }

  func testBackgroundUSBConnectDrainsBeforeWiFiActivationOrJoin() async throws {
    let usb = try await FixtureEnvironment.make()
    let fixture = Fixture(ownership: usb.environment.wirelessOwnership)
    await fixture.start()
    let nativeOpen = FixtureBarrier()
    let nativeClose = FixtureBarrier()
    await usb.camera.holdConnect(nativeOpen)
    await usb.camera.holdDisconnect(nativeClose)
    let model = AppModel(environment: usb.environment)
    await model.start()
    await nativeOpen.entered()

    let wifi = Task { await fixture.coordinator.connectWiFi() }
    try await waitUntilUSBReserved(usb.environment.cameraUseArbiter)
    XCTAssertFalse(fixture.log.events.contains("credentials"))
    XCTAssertFalse(fixture.log.events.contains("native join"))
    do {
      try await usb.environment.camera.resetConnection()
      XCTFail("USB reset entered a Wi-Fi reservation")
    } catch WirelessFailure.cameraBusy {}

    await nativeOpen.release()
    await nativeClose.entered()
    XCTAssertFalse(fixture.log.events.contains("credentials"))
    XCTAssertFalse(fixture.log.events.contains("native join"))
    await nativeClose.release()
    await wifi.value
    let closed = await usb.camera.disconnectCount
    XCTAssertEqual(closed, 1)
    XCTAssertEqual(fixture.log.events.filter { $0 == "credentials" || $0 == "native join" },
                   ["credentials", "native join"])
    await fixture.coordinator.disconnectWiFi()
  }

  func testUnconfirmedUSBCloseRetainsOwnership() async throws {
    let usb = try await FixtureEnvironment.make()
    try await usb.environment.camera.connect()
    await usb.camera.setConfirmedCloseFailure(.closeUnconfirmed)
    let fixture = Fixture(ownership: usb.environment.wirelessOwnership)
    await fixture.start()

    await fixture.coordinator.connectWiFi()
    await usb.camera.setConfirmedCloseFailure(nil)
    await fixture.coordinator.connectWiFi()
    XCTAssertEqual(fixture.log.events.filter { $0 == "credentials" }.count, 0)
    XCTAssertEqual(fixture.log.events.filter { $0 == "native join" }.count, 0)
    let attempts = await usb.camera.disconnectCount
    XCTAssertEqual(attempts, 1)
    let state = await snapshot(fixture.coordinator)
    XCTAssertEqual(state.wifiFailure, .usbCloseUnconfirmed)
    XCTAssertEqual(state.wifiFailurePhase, .acquiringOwnership)

    try await usb.environment.camera.disconnectConfirmed()
    await fixture.coordinator.connectWiFi()
    let recovered = await snapshot(fixture.coordinator)
    XCTAssertEqual(recovered.wifi, .ready)
    await fixture.coordinator.disconnectWiFi()
  }

  func testRecipeImportCleanupDrainsBeforeUSBHandoffClose() async throws {
    let usb = try await FixtureEnvironment.make(cameraModel: "X-E3")
    try await usb.environment.camera.connect()
    let cleanup = FixtureBarrier()
    await usb.camera.holdImport(cleanup)
    let importing = Task { try await usb.environment.camera.importRecipes() }
    await cleanup.entered()
    let fixture = Fixture(ownership: usb.environment.wirelessOwnership)
    await fixture.start()
    let wifi = Task { await fixture.coordinator.connectWiFi() }
    try await waitUntilUSBReserved(usb.environment.cameraUseArbiter)

    let closes = await usb.camera.disconnectCount
    XCTAssertEqual(closes, 0)
    XCTAssertFalse(fixture.log.events.contains("credentials"))
    XCTAssertFalse(fixture.log.events.contains("native join"))
    await cleanup.release()
    _ = try await importing.value
    await wifi.value
    let ready = await snapshot(fixture.coordinator)
    XCTAssertEqual(ready.wifi, .ready)
    await fixture.coordinator.disconnectWiFi()
  }

  func testUnconfirmedWirelessCloseKeepsUSBBlockedUntilRetry() async throws {
    let usb = try await FixtureEnvironment.make()
    let close = WirelessCloseFixture()
    let fixture = Fixture(ownership: usb.environment.wirelessOwnership, close: close)
    await fixture.start()
    await fixture.coordinator.connectWiFi()
    await fixture.coordinator.disconnectWiFi()

    do {
      try await usb.environment.camera.connect()
      XCTFail("USB opened after a failed wireless close")
    } catch WirelessFailure.cameraBusy {}
    let failed = await snapshot(fixture.coordinator)
    XCTAssertEqual(failed.wifiFailurePhase, .disconnecting)
    XCTAssertFalse(failed.showsCameraPhotosButton)
    let first = await usb.camera.connectCount
    XCTAssertEqual(first, 0)

    await close.allowClose()
    await fixture.coordinator.disconnectWiFi()
    try await usb.environment.camera.connect()
    let connects = await usb.camera.connectCount
    XCTAssertEqual(connects, 1)
  }

  func testIdleLossWithClosedSocketReleasesOwnershipDespiteCameraSettingFailure() async throws {
    let close = WirelessCloseFixture()
    let fixture = Fixture(close: close)
    await fixture.start()
    await fixture.coordinator.connectWiFi()
    await close.loseConnectionAfterSocketCloses()
    let deadline = ContinuousClock.now + .seconds(3)
    while await fixture.coordinator.currentState().wifiFailure == nil && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let settled = await fixture.coordinator.currentState()
    XCTAssertEqual(settled.wifi, .idle)
    XCTAssertFalse(settled.hasTransferLease)
    XCTAssertEqual(settled.wifiFailure, .connectionLost)
    XCTAssertEqual(settled.wifiFailurePhase, .ready)
    XCTAssertTrue(settled.cameraTransferSizeRestoreUnconfirmed)
    await fixture.coordinator.connectWiFi()
    let reconnected = await fixture.coordinator.currentState()
    XCTAssertEqual(reconnected.wifi, .ready)
    XCTAssertFalse(reconnected.cameraTransferSizeRestoreUnconfirmed)
    await close.allowClose()
    await fixture.coordinator.disconnectWiFi()
  }

  func testUSBWaitsForNativeBluetoothCloseAndAfterUSBDisconnectBluetoothCanReconnect() async throws {
    let usb = try await FixtureEnvironment.make()
    let fixture = Fixture(ownership: usb.environment.wirelessOwnership)
    try await usb.environment.cameraUseArbiter.installBluetoothController(fixture.coordinator)
    await fixture.start()
    let close = FixtureBarrier()
    fixture.bluetooth.disconnectBarrier = close
    let connecting = Task { try await usb.environment.camera.connect() }
    await close.entered()
    await fixture.coordinator.retryBluetooth()
    let first = await usb.camera.connectCount
    XCTAssertEqual(first, 0)
    XCTAssertEqual(fixture.log.events.filter { $0 == "authenticated" }.count, 1)

    await close.release()
    try await connecting.value
    await fixture.coordinator.retryBluetooth()
    let suspended = await snapshot(fixture.coordinator)
    XCTAssertEqual(suspended.bluetooth, .idle)

    try await usb.environment.camera.disconnectConfirmed()
    await fixture.start()
    XCTAssertEqual(fixture.log.events.filter { $0 == "authenticated" }.count, 2)
  }

  func testCancelledUSBDiscoveryRestoresBluetoothAfterNativeDrain() async throws {
    let usb = try await FixtureEnvironment.make()
    let fixture = Fixture(ownership: usb.environment.wirelessOwnership)
    try await usb.environment.cameraUseArbiter.installBluetoothController(fixture.coordinator)
    await fixture.start()
    let close = FixtureBarrier()
    fixture.bluetooth.disconnectBarrier = close
    let connecting = Task { try await usb.environment.camera.connect() }
    await close.entered()
    connecting.cancel()

    await fixture.coordinator.retryBluetooth()
    let suspended = await snapshot(fixture.coordinator)
    XCTAssertEqual(suspended.bluetooth, .idle)
    XCTAssertEqual(fixture.log.events.filter { $0 == "authenticated" }.count, 1)
    await close.release()
    do {
      try await connecting.value
      XCTFail("The cancelled discovery should never enter USB")
    } catch is CancellationError {}

    let calls = (await usb.camera.connectCount, await usb.camera.disconnectCount)
    XCTAssertEqual(calls.0, 0)
    XCTAssertEqual(calls.1, 0)
    let resumed = await snapshot(fixture.coordinator)
    XCTAssertTrue(resumed.bluetooth == .connecting || resumed.bluetooth == .ready)
  }

  private func waitUntilUSBReserved(_ arbiter: CameraUseArbiter) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
      do { try await arbiter.withUSB {} }
      catch WirelessFailure.cameraBusy { return }
      await Task.yield()
    }
    XCTFail("Wireless did not reserve USB ownership")
  }

  func testAutoSaveSetupWaitsForVerificationAndKeepsCameraOwnership() async throws {
    let gateway = HandoffAutoSave()
    let fixture = Fixture(model: .xe3, autoSave: gateway)
    await fixture.start()
    let setup = Task { await fixture.coordinator.setUpAutoSave() }
    await gateway.verifying.entered()
    let verifying = await snapshot(fixture.coordinator)
    XCTAssertEqual(verifying.wifi, .verifyingAutoSave)
    await fixture.coordinator.connectWiFi()
    XCTAssertEqual(fixture.log.events.filter { $0 == "ownership" }.count, 1)
    XCTAssertFalse(fixture.log.events.contains("credentials"))
    await expectNoSession(fixture.coordinator)

    await gateway.verifying.release()
    await setup.value
    let registered = await snapshot(fixture.coordinator)
    XCTAssertNil(registered.wifiFailure)
    XCTAssertEqual(registered.verifiedAutoSaveCameraID, fixture.id)
    XCTAssertEqual(fixture.log.events.filter { $0 == "release ownership" }.count, 1)
    await fixture.coordinator.waitForAutoSave()
    let ready = await snapshot(fixture.coordinator)
    XCTAssertEqual(ready.wifi, .ready)
    let peer = try await fixture.coordinator.transferSession().open()
    XCTAssertEqual(peer.model, .xe3)
    await fixture.coordinator.disconnectWiFi()
    let cleanup = fixture.log.events.filter { $0 == "close socket" || $0 == "release ownership" }
    XCTAssertEqual(Array(cleanup.suffix(2)), ["close socket", "release ownership"])
    XCTAssertFalse(fixture.log.events.contains("native join"))
  }

  func testBackgroundDrainsAutoSaveBeforeReleasingOwnershipAndDiscardsLateSession() async {
    let gateway = HandoffAutoSave()
    let fixture = Fixture(model: .xe3, autoSave: gateway)
    await fixture.start()
    await gateway.verifying.release()
    await fixture.coordinator.setUpAutoSave()
    gateway.holdWait()
    let connect = Task { await fixture.coordinator.waitForAutoSave() }
    await gateway.waiting.entered()
    let background = Task { await fixture.coordinator.setActivity(.background) }
    await gateway.cancelled.entered()
    XCTAssertEqual(fixture.log.events.filter { $0 == "release ownership" }.count, 1)
    await gateway.cancelled.release()
    await background.value
    await connect.value
    XCTAssertEqual(Array(fixture.log.events.suffix(2)), ["close socket", "release ownership"])
    XCTAssertFalse(fixture.log.events.contains("inventory"))
    await expectNoSession(fixture.coordinator)
  }

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

  func testXT5FirmwareFromBothPeersAllowsInventoryOn431() async {
    let fixture = Fixture(peerFirmware: "4.31", bluetoothFirmware: "04.31")
    await fixture.start()
    await fixture.coordinator.connectWiFi()
    let state = await snapshot(fixture.coordinator)
    XCTAssertEqual(state.wifi, .ready)
    XCTAssertNil(state.firmwareRejection)
    XCTAssertTrue(fixture.log.events.contains("inventory"))
    await fixture.coordinator.disconnectWiFi()
  }

  func testFirmwareFailureKeepsFreshTransferEvidenceForGuidance() async {
    for (peer, bluetooth, expected, bluetoothRejected) in [
      ("4.29", "4.32", WirelessAdmission.updateRequired("4.30"), false),
      ("4.31.0", "4.32", .unverified(.unreadable), false),
      (nil, "4.32", .unverified(.unreadable), false),
      ("4.32", "4.29", .supported(.xt5), true),
    ] as [(String?, String?, WirelessAdmission, Bool)] {
      let fixture = Fixture(peerFirmware: peer, bluetoothFirmware: bluetooth)
      await fixture.start()
      await fixture.coordinator.connectWiFi()
      let state = await snapshot(fixture.coordinator)
      XCTAssertEqual(state.wifiFailure, .unsupportedFirmware)
      XCTAssertEqual(state.firmwareRejection?.cameraModel, .xt5)
      XCTAssertEqual(state.firmwareRejection?.transferAdmission, expected)
      XCTAssertEqual(state.firmwareRejection?.bluetoothRejectedFirmware, bluetoothRejected)
      XCTAssertFalse(fixture.log.events.contains("inventory"))
    }
  }

  func testExplicitProbeKeepsExactRejectedFirmwareOutOfSharedState() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }

    let malformed = "peer-only\nprivate report"
    for (transfer, bluetooth) in [(" Ver.4.29 ", "4.32"), ("4.32", malformed), (malformed, "4.32")] {
      let fixture = Fixture(peerFirmware: transfer, bluetoothFirmware: bluetooth)
      await fixture.coordinator.observeProbeFirmware { evidence in
        try? WirelessProbeFirmwareEvidence.record(evidence, in: folder)
      }
      await fixture.start()
      await fixture.coordinator.connectWiFi()
      let rejected = await snapshot(fixture.coordinator)
      let message = try XCTUnwrap(rejected.firmwareRejection?.presentationGuidance)
      XCTAssertEqual(rejected.wifiFailure, .unsupportedFirmware)
      XCTAssertFalse(String(reflecting: rejected.firmwareRejection).contains(malformed))
      XCTAssertFalse(message.contains(malformed))
      XCTAssertFalse(fixture.log.events.contains("inventory"))
    }

    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    let reports = try files.map { try JSONDecoder().decode(WirelessProbeFirmwareEvidence.self, from: Data(contentsOf: $0)) }
    XCTAssertEqual(reports.count, 3)
    XCTAssertTrue(reports.allSatisfy { $0.model == .xt5 && $0.source == .cameraNetwork })
    XCTAssertTrue(reports.contains { $0.transferFirmware == " Ver.4.29 " && $0.bluetoothFirmware == "4.32" })
    XCTAssertTrue(reports.contains { $0.transferFirmware == "4.32" && $0.bluetoothFirmware == malformed })
    XCTAssertTrue(reports.contains { $0.transferFirmware == malformed && $0.bluetoothFirmware == "4.32" })
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

  func testAuthenticationFailureDuringHandoffPreservesBluetoothWaitPhase() async {
    let fixture = Fixture()
    let reconnect = HandoffBarrier()
    fixture.bluetooth.reconnectBarrier = reconnect
    fixture.bluetooth.reconnectFailure = .authentication
    await fixture.coordinator.setActivity(.active)
    let states = await fixture.coordinator.states()
    var iterator = states.makeAsyncIterator()
    let connect = Task { await fixture.coordinator.connectWiFi() }
    while let state = await iterator.next(), state.wifi != .waitingForBluetooth {}
    await reconnect.release()
    await connect.value
    let state = await snapshot(fixture.coordinator)
    XCTAssertEqual(state.wifiFailure, .authentication)
    XCTAssertEqual(state.wifiFailurePhase, .waitingForBluetooth)
    XCTAssertFalse(fixture.log.events.contains("credentials"))
    XCTAssertFalse(fixture.log.events.contains("native join"))
    XCTAssertEqual(fixture.log.events.last, "release ownership")
  }

  func testLateIdentityAfterBluetoothDropPreservesActivationFailure() async {
    let fixture = Fixture()
    let identity = HandoffBarrier()
    fixture.bluetooth.identityBarrier = identity
    await fixture.start()
    let states = await fixture.coordinator.states()
    var iterator = states.makeAsyncIterator()
    let connect = Task { await fixture.coordinator.connectWiFi() }
    await identity.entered()
    fixture.bluetooth.drop()
    while let state = await iterator.next(), state.bluetooth == .ready {}
    let interrupted = await snapshot(fixture.coordinator)
    XCTAssertEqual(interrupted.wifiFailure, .connectionLost)
    XCTAssertEqual(interrupted.wifiFailurePhase, .activatingCamera)
    await identity.release()
    await connect.value
    let state = await snapshot(fixture.coordinator)
    XCTAssertEqual(state.wifiFailure, .connectionLost)
    XCTAssertEqual(state.wifiFailurePhase, .activatingCamera)
    XCTAssertFalse(fixture.log.events.contains("credentials"))
    XCTAssertFalse(fixture.log.events.contains("native join"))
    XCTAssertTrue(fixture.log.events.contains("release ownership"))
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

  init(
    failure: WirelessFailure? = nil, model: WirelessCameraModel = .xt5, autoSave: HandoffAutoSave? = nil,
    ownership: (any WirelessCameraOwnershipGateway)? = nil, close: WirelessCloseFixture? = nil,
    peerFirmware: String? = "4.32", bluetoothFirmware: String? = "4.32", manualRoute: HandoffBarrier? = nil
  ) {
    let camera = SavedCamera(id: id, peripheralID: UUID(), model: model, displayName: "Fixture")
    let bluetooth = HandoffBluetooth(id: id, log: log, failure: failure, firmware: bluetoothFirmware)
    let gateway = HandoffWiFi(log: log, failure: failure)
    let log = self.log
    self.bluetooth = bluetooth
    self.gateway = gateway
    coordinator = WirelessConnectionCoordinator(
      bluetooth: bluetooth, store: HandoffStore(camera: camera),
      authorization: { .allowed }, credentials: manualRoute == nil ? nil : PasswordFixture(),
      wifi: manualRoute == nil ? gateway : nil, ownership: ownership ?? HandoffOwner(log: log),
      sessionFactory: { identity, _ in
        if let manualRoute { await manualRoute.wait() }
        await log.record("allocate socket")
        let peer = WirelessIdentity(cameraID: identity.cameraID, model: identity.model, firmware: peerFirmware,
                                    protocolPeerKey: identity.protocolPeerKey)
        return HandoffSession(identity: peer, log: log, failure: failure, closeFixture: close)
      }, autoSave: autoSave)
    autoSave?.use(log: log)
  }

  func start() async {
    await coordinator.setActivity(.active)
    let stream = await coordinator.states()
    var iterator = stream.makeAsyncIterator()
    while let state = await iterator.next(), state.bluetooth != .ready {}
  }
}

@MainActor
private final class HandoffAutoSave: AutoSaveGateway {
  let verifying = HandoffBarrier()
  let waiting = HandoffBarrier()
  let cancelled = HandoffBarrier()
  private var shouldWait = false
  private var log: HandoffLog?
  private var registration: AutoSaveRegistration?

  func use(log: HandoffLog) { self.log = log }
  func holdWait() { shouldWait = true }
  func checkAvailability() throws { try Task.checkCancellation() }

  func register(
    camera: SavedCamera, onRegistered: @escaping @Sendable () async throws -> Void
  ) async throws -> AutoSaveRegistration {
    try await onRegistered()
    await verifying.wait()
    let receipt = AutoSaveRegistration(
      cameraID: camera.id, peerKey: .init(bytes: Data(repeating: 1, count: 32)),
      importer: "FujiStudio-test", cameraName: "Fixture")
    registration = receipt
    return receipt
  }

  func savedRegistration(for cameraID: WirelessCameraID) throws -> AutoSaveRegistration {
    guard let registration, registration.cameraID == cameraID else {
      throw WirelessFailure.autoSaveRegistrationRequired
    }
    return registration
  }

  func waitForSession(registration: AutoSaveRegistration) async throws -> any WirelessTransferSession {
    if shouldWait { await waiting.wait() }
    let log = try XCTUnwrap(log)
    return HandoffSession(
      identity: .init(
        cameraID: registration.cameraID, model: .xe3, firmware: "1.32", protocolPeerKey: registration.peerKey),
      log: log, failure: nil)
  }

  func cancel() async {
    if shouldWait {
      await cancelled.wait()
      await waiting.release()
    }
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
  let firmware: String?
  let notifications = AsyncStream<BluetoothGatewayEvent>.makeStream()
  var reconnectBarrier: HandoffBarrier?
  var reconnectFailure: WirelessFailure?
  var identityBarrier: HandoffBarrier?
  var disconnectBarrier: FixtureBarrier?

  init(id: WirelessCameraID, log: HandoffLog, failure: WirelessFailure?, firmware: String?) {
    self.id = id
    self.log = log
    self.failure = failure
    self.firmware = firmware
  }

  func discover() async throws -> AsyncThrowingStream<[DiscoveredCamera], any Error> {
    throw WirelessFailure.unsupportedProtocol
  }
  func pair(_ camera: DiscoveredCamera) async throws -> SavedCamera {
    throw WirelessFailure.unsupportedProtocol
  }
  func reconnect(_ camera: SavedCamera, allowPermissionPrompt: Bool) async throws {
    if let reconnectBarrier { await reconnectBarrier.wait() }
    if let reconnectFailure { throw reconnectFailure }
    log.record("authenticated")
  }
  func identity(for id: WirelessCameraID) async throws -> WirelessIdentity {
    log.record("BLE identity")
    if let identityBarrier { await identityBarrier.wait() }
    return .init(cameraID: id, model: .xt5, firmware: firmware)
  }
  func activateWiFi(for id: WirelessCameraID) async throws -> CameraNetwork {
    log.record("credentials")
    if let failure, [.malformedData, .timeout(.wifiReadiness)].contains(failure) { throw failure }
    log.record("camera ready")
    return network(id: id)
  }
  func events() async -> AsyncStream<BluetoothGatewayEvent> { notifications.stream }
  func disconnect() async {
    if let disconnectBarrier { await disconnectBarrier.wait() }
  }
  func drop() { notifications.continuation.yield(.disconnected(id, .connectionLost)) }
}

private actor HandoffBarrier {
  private var released = false
  private var didEnter = false
  private var waiter: CheckedContinuation<Void, Never>?
  private var observer: CheckedContinuation<Void, Never>?

  func wait() async {
    didEnter = true
    observer?.resume()
    observer = nil
    if !released { await withCheckedContinuation { waiter = $0 } }
  }

  func entered() async {
    if !didEnter { await withCheckedContinuation { observer = $0 } }
  }

  func release() {
    released = true
    waiter?.resume()
    waiter = nil
  }
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

private struct HandoffSession: WirelessSessionMonitoring {
  let identity: WirelessIdentity
  let log: HandoffLog
  let failure: WirelessFailure?
  var closeFixture: WirelessCloseFixture? = nil

  var transportClosed: Bool { get async { await closeFixture?.transportClosed ?? false } }
  var connectionFailures: AsyncStream<WirelessFailure> { closeFixture?.stream ?? AsyncStream { $0.finish() } }

  func open() async throws -> WirelessIdentity {
    await log.record("PTP identity")
    if failure == .timeout(.tcpSetup) { throw WirelessFailure.timeout(.tcpSetup) }
    if failure == .peerMismatch { return .init(cameraID: .init(), model: .xt5, firmware: "4.32") }
    if failure == .unsupportedFirmware {
      return .init(cameraID: identity.cameraID, model: .xt5, firmware: "4.29")
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
  func close() async throws {
    await log.record("close socket")
    try await closeFixture?.confirmClose()
  }
}

private actor WirelessCloseFixture {
  private let failures = AsyncStream<WirelessFailure>.makeStream()
  nonisolated var stream: AsyncStream<WirelessFailure> { failures.stream }
  private(set) var transportClosed = false
  func loseConnectionAfterSocketCloses() {
    transportClosed = true
    failures.continuation.yield(.connectionLost)
  }
  private var allowed = false
  func allowClose() { allowed = true }
  func confirmClose() throws {
    guard allowed else { throw WirelessFailure.connectionLost }
  }
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
