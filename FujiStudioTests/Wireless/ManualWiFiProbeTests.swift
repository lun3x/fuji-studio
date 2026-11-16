#if targetEnvironment(simulator)
import CryptoKit
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
    #expect(probe.galleryResult?.cards.first?.summary.scannedCount == 2)
    #expect(probe.status.contains("Wi-Fi identity is unavailable"))
    #expect(probe.status.contains("Connection closed after the test."))
    #expect(probe.handoff == nil)

    probe.connect(.saved(fixture.otherCamera))
    #expect(probe.galleryResult == nil)
    await probe.waitForOperation()
  }

  @Test func pairTestClosesWithoutDownloadWhenNoPairIsCorroborated() async {
    let fixture = ManualWiFiFixture()
    let probe = fixture.probe
    await prepareHandoff(fixture)
    probe.testPairDownload()
    #expect(await fixture.transfer.actions.isEmpty)
    probe.confirmJoined()
    probe.testPairDownload()
    await probe.waitForOperation()
    #expect(await fixture.transfer.actions == [.listPhotos, .close])
    #expect(probe.galleryResult?.cards.first?.summary.scannedCount == 2)
    #expect(probe.status.contains("No unambiguous JPEG+RAW pair"))
    #expect(probe.pairResult == nil)
  }

  @Test func publishesProtectedPairOnlyAfterCloseAndPreservesItWhenNextTestIsCancelled() async throws {
    let files = try ImportFileFixture(location: true)
    defer { files.cleanUp() }
    let fixture = ManualWiFiFixture(pairRoot: files.root)
    let probe = fixture.probe
    await fixture.transfer.setGalleryFiles([files.object(.raf): files.raf, files.object(.jpeg): files.jpeg])
    let close = AsyncStream<Void>.makeStream()
    await fixture.transfer.holdGalleryClose(entered: close.continuation)
    await prepareHandoff(fixture)
    probe.confirmJoined()
    probe.testPairDownload()
    for await _ in close.stream { break }
    let completed = files.root.appending(path: "completed")
    let manifest = completed.appending(path: "manifest.json")
    #expect(!FileManager.default.fileExists(atPath: manifest.path))
    #expect(probe.pairResult == nil)
    #expect(probe.keepsScreenAwake)
    #expect(probe.scanProgress?.latest.file?.receivedBytes == UInt64(files.jpeg.count))
    await fixture.transfer.releaseHeldGalleryCloseForTest()
    await probe.waitForOperation()
    #expect(!probe.keepsScreenAwake)
    let result = try #require(probe.pairResult)
    #expect(result.files.map(\.role) == [.raf, .jpeg])
    let manifestBytes = try Data(contentsOf: manifest)
    #expect(try JSONDecoder().decode(ManualWiFiPairReceipt.self, from: manifestBytes) == result)
    for (file, expected) in zip(result.files, [files.raf, files.jpeg]) {
      #expect(file.expectedBytes == UInt64(expected.count))
      #expect(file.actualBytes == UInt64(expected.count))
      #expect(file.sha256 == SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined())
      #expect(try Data(contentsOf: completed.appending(path: file.relativePath)) == expected)
      #expect(!file.relativePath.contains("DSCF"))
      #expect(file.originalControl == .reported(2))
    }
    #expect(await fixture.transfer.actions == [.listPhotos, .download(.raf), .download(.jpeg), .close])
    #expect(try FileManager.default.contentsOfDirectory(atPath: files.root.path) == ["completed"])

    let retry = ManualWiFiFixture(pairRoot: files.root)
    await retry.transfer.setGalleryFiles([files.object(.raf): files.raf, files.object(.jpeg): files.jpeg])
    let retryClose = AsyncStream<Void>.makeStream()
    await retry.transfer.holdGalleryClose(entered: retryClose.continuation)
    await prepareHandoff(retry)
    retry.probe.confirmJoined()
    retry.probe.testPairDownload()
    for await _ in retryClose.stream { break }
    retry.probe.sceneChanged(.background)
    #expect(!retry.probe.keepsScreenAwake)
    await retry.probe.waitForOperation()
    #expect(await retry.transfer.galleryAbortCount == 1)
    #expect(retry.probe.pairResult == nil)
    #expect(retry.probe.galleryResult == nil)
    #expect(try Data(contentsOf: manifest) == manifestBytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: files.root.path) == ["completed"])

    let replacement = ManualWiFiFixture(pairRoot: files.root)
    await replacement.transfer.setGalleryFiles([files.object(.raf): files.raf, files.object(.jpeg): files.jpeg])
    await prepareHandoff(replacement)
    replacement.probe.confirmJoined()
    replacement.probe.testPairDownload()
    await replacement.probe.waitForOperation()
    let replacementResult = try #require(replacement.probe.pairResult)
    #expect(replacementResult.files.map(\.relativePath) != result.files.map(\.relativePath))
    #expect(try FileManager.default.contentsOfDirectory(atPath: files.root.path) == ["completed"])
    #expect(!FileManager.default.fileExists(atPath: completed.appending(path: result.files[0].relativePath).path))
  }

  @Test(arguments: ["short", "signature", "metadata", "capture"]) func failedSecondFileLeavesNoPrivatePair(fault: String) async throws {
    let files = try ImportFileFixture(jpegDate: fault == "capture" ? "2023:01:02 03:04:05" : "2020:01:02 03:04:05")
    defer { files.cleanUp() }
    let fixture = ManualWiFiFixture(pairRoot: files.root)
    var jpeg = files.jpeg
    if fault == "short" { jpeg.removeLast() }
    if fault == "signature" { jpeg[0] = 0 }
    let jpegObject = files.object(.jpeg, dimensions: fault == "metadata" ? .init(width: 7, height: 4) : nil)
    await fixture.transfer.setGalleryFiles([files.object(.raf): files.raf, jpegObject: jpeg])
    await prepareHandoff(fixture)
    fixture.probe.confirmJoined()
    fixture.probe.testPairDownload()
    await fixture.probe.waitForOperation()
    #expect(await fixture.transfer.actions == [.listPhotos, .download(.raf), .download(.jpeg), .close])
    #expect(fixture.probe.galleryResult?.cards.first?.summary.scannedCount == 2)
    #expect(fixture.probe.pairResult == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: files.root.path).isEmpty)
  }

  @Test func selectionUsesCorroborationAndPrefersSameCard() throws {
    let files = try ImportFileFixture()
    let scan = XAppGalleryDiagnosticResult(wifiIdentityAvailable: false, cards: [
      .init(slot: 1, totalHandles: 0, samples: []), .init(slot: 2, totalHandles: 0, samples: [])
    ])
    let raw = files.object(.raf, filename: "SAME.RAF")
    let mismatch = makeMate(of: raw, handle: 2, storage: 1, date: "20230102T030405")
    let jpeg = makeMate(of: raw, handle: 3, storage: 1)
    let duplicate = makeMate(of: raw, handle: 4, storage: 1)
    #expect(ManualWiFiPair.select(from: [raw, mismatch], scan: scan) == nil)
    #expect(ManualWiFiPair.select(from: [raw, jpeg, duplicate], scan: scan) == nil)

    let newer = WirelessObjectDescriptor(cameraID: raw.cameraID, sessionID: raw.sessionID, storageID: 1, handle: 5,
      directory: raw.directory, filename: "NEWER.RAF", format: .raf, byteLength: 21,
      captureDate: "20240102T030405", dimensions: raw.dimensions)
    let split = makeMate(of: newer, handle: 5, storage: 2)
    #expect(ManualWiFiPair.select(from: [newer, split], scan: scan)?.jpeg == split)
    #expect(ManualWiFiPair.select(from: [raw, mismatch, jpeg, newer, split], scan: scan)?.jpeg == jpeg)
  }

  private func makeMate(of raw: WirelessObjectDescriptor, handle: UInt32, storage: UInt32,
                        date: String? = nil) -> WirelessObjectDescriptor {
    .init(cameraID: raw.cameraID, sessionID: raw.sessionID, storageID: storage, handle: handle,
      directory: raw.directory, filename: String(raw.filename.dropLast(3)) + "JPG", format: .jpeg,
      byteLength: 31, captureDate: date ?? raw.captureDate, dimensions: raw.dimensions, orientation: raw.orientation)
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
