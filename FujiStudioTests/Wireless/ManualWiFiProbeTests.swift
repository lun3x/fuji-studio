#if targetEnvironment(simulator)
import FujiCameraCore
import Testing
@testable import FujiStudio

@MainActor
struct ManualWiFiProbeTests {
  @Test func selectsDiagnosticOnNormalLaunchOfDiagnosticBuild() {
    #expect(FixtureEnvironment.route(arguments: [], unitHost: false, manualWiFi: true) == .manualWiFi)
    #expect(FixtureEnvironment.route(arguments: [], unitHost: false) == .live)
    #expect(FixtureEnvironment.route(arguments: [], unitHost: true, manualWiFi: true) == .unitHost)
  }

  @Test func closesIdentitySessionWithoutAnyTransfer() async throws {
    let fixture = ManualWiFiFixture()
    let probe = fixture.probe
    probe.connect(.saved(fixture.camera))
    await probe.waitForOperation()
    #expect(probe.handoff != nil)
    probe.identify()
    #expect(probe.handoff != nil)
    #expect(await fixture.transfer.actions.isEmpty)
    probe.confirmJoined()
    probe.identify()
    await probe.waitForOperation()
    #expect(await fixture.transfer.actions == [.open, .close])
    #expect(probe.status == "X-T5 identified. Firmware 04.31.")
    #expect(probe.handoff == nil)
  }

  @Test func selectionChangeRequiresASeparateFreshConfirmation() async {
    let fixture = ManualWiFiFixture()
    let probe = fixture.probe
    probe.connect(.saved(fixture.camera))
    await probe.waitForOperation()
    probe.confirmJoined()
    probe.connect(.saved(fixture.otherCamera))
    await probe.waitForOperation()
    #expect(probe.handoff?.credential.cameraID == fixture.otherCamera.id)
    #expect(!probe.userConfirmed)
    probe.identify()
    #expect(await fixture.transfer.actions.isEmpty)
  }

  @Test func returningFromBackgroundRequiresFreshConfirmation() async {
    let fixture = ManualWiFiFixture()
    let probe = fixture.probe
    probe.connect(.saved(fixture.camera))
    await probe.waitForOperation()
    probe.confirmJoined()
    probe.sceneChanged(.inactive)
    #expect(probe.userConfirmed)
    probe.sceneChanged(.background)
    probe.sceneChanged(.active)
    #expect(probe.handoff != nil)
    #expect(!probe.canIdentify)
    #expect(probe.canConfirm)
    probe.confirmJoined()
    #expect(probe.canIdentify)
  }

  @Test func watchdogInvalidatesHandoffWhileHoldingLeaseThroughDisconnect() async {
    let fixture = ManualWiFiFixture()
    let probe = fixture.probe
    probe.connect(.saved(fixture.camera))
    await probe.waitForOperation()
    probe.revealPassword()
    probe.confirmJoined()
    probe.sceneChanged(.inactive)
    #expect(probe.handoff != nil)
    #expect(probe.visiblePassword == nil)
    probe.sceneChanged(.background)
    let disconnect = FixtureBarrier()
    await fixture.bluetooth.holdDisconnect(disconnect)
    fixture.expireLease(.watchdog)
    #expect(probe.handoff == nil)
    #expect(!probe.userConfirmed)
    await disconnect.entered()
    #expect(fixture.leaseHeld)
    await disconnect.release()
    await probe.waitForOperation()
    #expect(!fixture.leaseHeld)
    #expect(await fixture.bluetooth.disconnectCount == 1)
  }

  @Test func hardDeadlineReleasesLeaseWithoutWaitingForPendingDisconnect() async {
    let fixture = ManualWiFiFixture()
    let probe = fixture.probe
    probe.connect(.saved(fixture.camera))
    await probe.waitForOperation()
    probe.sceneChanged(.background)
    let disconnect = FixtureBarrier()
    await fixture.bluetooth.holdDisconnect(disconnect)
    fixture.expireLease(.watchdog)
    await disconnect.entered()
    fixture.expireLease(.hardDeadline)
    #expect(!fixture.leaseHeld)
    #expect(probe.handoff == nil)
    await disconnect.release()
    await probe.waitForOperation()
    #expect(await fixture.bluetooth.disconnectCount == 1)
  }

  @Test func activationTimeoutKeepsItsReasonWhenDisconnectArrivesFirst() async {
    let fixture = ManualWiFiFixture()
    let barrier = FixtureBarrier()
    let failure = WirelessFailure.timeout(.wifiReadiness)
    await fixture.bluetooth.holdActivation(barrier, thenThrow: failure)
    let probe = fixture.probe
    probe.connect(.saved(fixture.camera))
    await barrier.entered()
    probe.bluetoothEvent(.disconnected(fixture.camera.id, failure))
    await barrier.release()
    await probe.waitForOperation()
    #expect(fixture.events.last?.phase == .activationFailed)
    #expect(fixture.events.last?.failure == .wifiReadinessTimeout)
    #expect(probe.status == "Camera Wi-Fi did not become ready. Check the camera and retry.")
  }

  @Test func cancellingSuspendedActivationCannotPublishStaleCredentials() async {
    let fixture = ManualWiFiFixture()
    let barrier = FixtureBarrier()
    await fixture.bluetooth.holdActivation(barrier)
    let probe = fixture.probe
    probe.connect(.saved(fixture.camera))
    await barrier.entered()
    probe.cancel()
    await barrier.release()
    await probe.waitForOperation()
    #expect(probe.handoff == nil)
    #expect(probe.status == "Cancelled. Select a camera to retry.")
    #expect(await fixture.bluetooth.disconnectCount == 1)
  }

  @Test func losingBluetoothRetiresCurrentHandoff() async {
    let fixture = ManualWiFiFixture()
    let probe = fixture.probe
    probe.connect(.saved(fixture.camera))
    await probe.waitForOperation()
    probe.confirmJoined()
    probe.bluetoothEvent(.disconnected(fixture.camera.id, .connectionLost))
    await probe.waitForOperation()
    #expect(probe.handoff == nil)
    #expect(!probe.userConfirmed)
  }

  @Test func firmwareReportAcceptsOnlyBoundedVersionText() {
    #expect(ManualWiFiEvent.firmware("Ver. 04.31") == "04.31")
    #expect(ManualWiFiEvent.firmware("04.31 camera secret") == "unavailable")
    #expect(ManualWiFiEvent.firmware("1.23") == "unavailable")
  }
}
#endif
