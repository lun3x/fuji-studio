#if targetEnvironment(simulator)
import Foundation
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

  @Test(arguments: [false, true]) func closesConnectionCheckAndReportsEvidence(withoutDeviceInfo: Bool) async {
    let fixture = ManualWiFiFixture(withoutDeviceInfo: withoutDeviceInfo)
    let probe = fixture.probe
    probe.connect(.saved(fixture.camera))
    await probe.waitForOperation()
    probe.confirmRegistration()
    probe.startWiFi()
    await probe.waitForOperation()
    #expect(probe.handoff != nil)
    probe.identify()
    #expect(probe.handoff != nil)
    #expect(await fixture.transfer.actions.isEmpty)
    probe.confirmJoined()
    probe.identify()
    await probe.waitForOperation()
    #expect(await fixture.transfer.actions == [.open, .close])
    if withoutDeviceInfo {
      #expect(probe.status == "Wi-Fi session responds. Bluetooth reports X-T5 firmware 04.31. Wi-Fi identity is unavailable.")
      #expect(fixture.events.last?.phase == .sessionResponding)
    } else {
      #expect(probe.status == "X-T5 identified. Firmware 04.31.")
      #expect(fixture.events.last?.phase == .identified)
    }
    #expect(await fixture.bluetooth.disconnectCount == 1)
    #expect(!probe.userConfirmed)
    #expect(probe.visiblePassword == nil)
    #expect(probe.handoff == nil)
  }

  @Test func galleryRequiresManualConfirmationAndClosesBeforeRetainingResult() async {
    let fixture = ManualWiFiFixture(withoutDeviceInfo: true)
    let probe = fixture.probe
    await prepareHandoff(fixture)
    probe.listCameraPhotos()
    #expect(await fixture.transfer.actions.isEmpty)
    probe.confirmJoined()
    probe.listCameraPhotos()
    await probe.waitForOperation()
    #expect(await fixture.transfer.actions == [.listPhotos, .close])
    #expect(probe.galleryResult?.cards.first?.summary.sampledCount == 2)
    #expect(probe.status.contains("Wi-Fi identity is unavailable"))
    #expect(probe.status.contains("Connection closed after the test."))
    #expect(probe.handoff == nil)

    probe.connect(.saved(fixture.otherCamera))
    #expect(probe.galleryResult == nil)
    await probe.waitForOperation()
  }

  @Test func backgroundRetiresGalleryEvenIfTheSessionReturnsLate() async {
    let fixture = ManualWiFiFixture()
    let probe = fixture.probe
    await prepareHandoff(fixture)
    let barrier = FixtureBarrier()
    await fixture.transfer.holdGallery(barrier)
    probe.confirmJoined()
    probe.listCameraPhotos()
    await barrier.entered()
    probe.sceneChanged(.background)
    await barrier.release()
    await probe.waitForOperation()
    #expect(await fixture.transfer.actions.contains(.close))
    #expect(probe.galleryResult == nil)
    #expect(fixture.events.last?.phase == .leftDuringOperation)
  }

  @Test func galleryDeadlineClosesTheSessionAndDoesNotPublishResults() async {
    let fixture = ManualWiFiFixture(galleryDeadline: .milliseconds(200))
    let probe = fixture.probe
    await prepareHandoff(fixture)
    await fixture.transfer.delayGallery(.seconds(90))
    probe.confirmJoined()
    probe.listCameraPhotos()
    await probe.waitForOperation()
    #expect(await fixture.transfer.actions == [.listPhotos, .close])
    #expect(probe.galleryResult == nil)
    #expect(fixture.events.last?.failure == .ptpTimeout)
  }

  @Test func galleryDeadlineAbortsAnInProgressGracefulClose() async {
    let fixture = ManualWiFiFixture(galleryDeadline: .milliseconds(500))
    let probe = fixture.probe
    await prepareHandoff(fixture)
    let (closings, closing) = AsyncStream<Void>.makeStream()
    await fixture.transfer.holdGalleryClose(entered: closing)
    probe.confirmJoined()
    probe.listCameraPhotos()
    for await _ in closings { break }
    // A fallback prevents a test hang if the deadline forgets to abort native I/O.
    let fallback = Task {
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      await fixture.transfer.releaseHeldGalleryCloseForTest()
    }
    await probe.waitForOperation()
    fallback.cancel()
    #expect(await fixture.transfer.galleryAbortCount == 1)
    #expect(await fixture.transfer.actions == [.listPhotos, .close])
    #expect(probe.galleryResult == nil)
    #expect(fixture.events.last?.failure == .ptpTimeout)
  }

  private func prepareHandoff(_ fixture: ManualWiFiFixture) async {
    let probe = fixture.probe
    probe.connect(.saved(fixture.camera))
    await probe.waitForOperation()
    probe.confirmRegistration()
    probe.startWiFi()
    await probe.waitForOperation()
  }

  @Test(arguments: [false, true]) func cameraRegistrationMustBeConfirmedBeforeStartingWiFi(pair: Bool) async {
    let fixture = ManualWiFiFixture()
    let probe = fixture.probe
    let nearby = DiscoveredCamera(peripheralID: fixture.camera.peripheralID,
      advertisedModelHint: .xt5, displayName: fixture.camera.displayName)
    probe.connect(pair ? .discovered(nearby) : .saved(fixture.camera))
    await probe.waitForOperation()
    #expect(fixture.events.last?.phase == .bluetoothLinked)
    #expect(fixture.events.last?.linkMode == (pair ? .pair : .reconnect))
    #expect(probe.canConfirmRegistration)
    probe.startWiFi()
    #expect(await fixture.bluetooth.activationCount == 0)
    #expect(probe.handoff == nil)

    probe.confirmRegistration()
    #expect(fixture.events.last?.phase == .registrationConfirmed)
    #expect(fixture.events.last?.linkMode == (pair ? .pair : .reconnect))
    #expect(await fixture.bluetooth.activationCount == 0)
    probe.startWiFi()
    await probe.waitForOperation()
    #expect(await fixture.bluetooth.activationCount == 1)
    #expect(probe.handoff != nil)
  }

  @Test(arguments: [false, true]) func retiringHeldLinkClearsRegistration(background: Bool) async {
    let fixture = ManualWiFiFixture()
    let probe = fixture.probe
    probe.connect(.saved(fixture.camera))
    await probe.waitForOperation()
    probe.confirmRegistration()
    if background {
      probe.sceneChanged(.inactive)
      #expect(probe.registrationConfirmed)
      probe.sceneChanged(.background)
      #expect(!fixture.leaseHeld)
    } else {
      probe.bluetoothEvent(.disconnected(fixture.camera.id, .connectionLost))
    }
    await probe.waitForOperation()
    #expect(!probe.registrationConfirmed)
    #expect(probe.linkedRecordID == nil)
    #expect(await fixture.bluetooth.disconnectCount == 1)
    #expect(await fixture.bluetooth.activationCount == 0)
  }

  @Test func findingPairedCameraWaitsForAUserSelectionBeforeConnecting() async {
    let fixture = ManualWiFiFixture()
    let probe = fixture.probe
    probe.findPairedCamera()
    await probe.waitForScan()
    #expect(probe.pairedNearby == [fixture.camera])
    #expect(await fixture.bluetooth.reconnectCount == 0)
    #expect(await fixture.bluetooth.discoverCount == 0)
    probe.reconnectNearby(fixture.otherCamera)
    #expect(await fixture.bluetooth.reconnectCount == 0)
    probe.reconnectNearby(fixture.camera)
    await probe.waitForOperation()
    #expect(await fixture.bluetooth.reconnectCount == 1)
    #expect(probe.linkedRecordID == fixture.camera.id)
    #expect(!probe.canStartWiFi)
  }

  @Test(arguments: [false, true]) func retiredFinderMustDrainBeforePairingOrReconnecting(background: Bool) async {
    let fixture = ManualWiFiFixture()
    let probe = fixture.probe
    let heldFinder = FixtureBarrier()
    fixture.finder.beforeReturn = heldFinder
    probe.findPairedCamera()
    await heldFinder.entered()
    if background {
      probe.sceneChanged(.background)
      probe.sceneChanged(.active)
    } else {
      probe.cancel()
    }
    probe.scanForPairing()
    probe.reconnectNearby(fixture.camera)
    probe.connect(.saved(fixture.camera))
    #expect(await fixture.bluetooth.discoverCount == 0)
    #expect(await fixture.bluetooth.reconnectCount == 0)
    await heldFinder.release()
    await probe.waitForOperation()
    #expect(probe.pairedNearby.isEmpty)
    probe.scanForPairing()
    await probe.waitForScan()
    #expect(await fixture.bluetooth.discoverCount == 1)
    #expect(probe.discovered.count == 1)
    #expect(probe.pairedNearby.isEmpty)
  }

  @Test func selectionChangeRequiresASeparateFreshConfirmation() async {
    let fixture = ManualWiFiFixture()
    let probe = fixture.probe
    probe.connect(.saved(fixture.camera))
    await probe.waitForOperation()
    probe.confirmRegistration()
    probe.startWiFi()
    await probe.waitForOperation()
    probe.confirmJoined()
    probe.connect(.saved(fixture.otherCamera))
    await probe.waitForOperation()
    #expect(!probe.registrationConfirmed)
    #expect(probe.linkedRecordID == fixture.otherCamera.id)
    probe.confirmRegistration()
    probe.startWiFi()
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
    probe.confirmRegistration()
    probe.startWiFi()
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
    probe.confirmRegistration()
    probe.startWiFi()
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
    probe.confirmRegistration()
    probe.startWiFi()
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
    await probe.waitForOperation()
    probe.confirmRegistration()
    probe.startWiFi()
    await barrier.entered()
    probe.bluetoothEvent(.disconnected(fixture.camera.id, failure))
    await barrier.release()
    await probe.waitForOperation()
    #expect(fixture.events.last?.phase == .activationFailed)
    #expect(fixture.events.last?.failure == .wifiReadinessTimeout)
    #expect(fixture.events.last?.launchMode == .standard)
    #expect(probe.status == "Camera Wi-Fi did not become ready. Check the camera and retry.")
  }

  @Test func cancellingSuspendedActivationCannotPublishStaleCredentials() async {
    let fixture = ManualWiFiFixture()
    let barrier = FixtureBarrier()
    await fixture.bluetooth.holdActivation(barrier)
    let probe = fixture.probe
    probe.connect(.saved(fixture.camera))
    await probe.waitForOperation()
    probe.confirmRegistration()
    probe.startWiFi()
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
    probe.confirmRegistration()
    probe.startWiFi()
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
