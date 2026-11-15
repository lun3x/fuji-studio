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

  @Test func leaseExpirationDiscardsSecretAndConfirmation() async {
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
    fixture.expireLease()
    await probe.waitForOperation()
    probe.sceneChanged(.active)
    #expect(probe.handoff == nil)
    #expect(!probe.userConfirmed)
    #expect(await fixture.bluetooth.disconnectCount == 1)
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
