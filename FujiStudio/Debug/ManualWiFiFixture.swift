#if DEBUG && targetEnvironment(simulator)
import CoreBluetooth
import Foundation
import FujiCameraCore

@MainActor
final class ManualWiFiFixture {
  @MainActor
  private final class Lease {
    var expiration: (@MainActor (ManualWiFiProbe.LeaseExpiration) -> Void)?
    var events: [ManualWiFiEvent] = []
  }

  let camera = SavedCamera(id: WirelessCameraID(), peripheralID: UUID(), model: .xt5, displayName: "Fixture X-T5")
  let otherCamera = SavedCamera(id: WirelessCameraID(), peripheralID: UUID(), model: .xt5, displayName: "Alternate X-T5")
  let bluetooth = Bluetooth()
  let transfer: Transfer
  let finder = SavedFinder()
  private let lease: Lease
  let probe: ManualWiFiProbe

  init(withoutDeviceInfo: Bool = false, galleryDeadline: Duration = .seconds(90),
       jpegOnly: Bool = false, pairRoot: URL? = nil) {
    let cameras = [camera, otherCamera]
    let lease = Lease()
    self.lease = lease
    let transfer = Transfer(withoutDeviceInfo: withoutDeviceInfo, jpegOnly: jpegOnly)
    self.transfer = transfer
    let finder = self.finder
    probe = ManualWiFiProbe(
      bluetooth: bluetooth, loadSaved: { cameras },
      findPaired: { try await finder.find($0) },
      password: { _ in "fixture-password" },
      authorizeLaunch: { _, _ in },
      makeSession: { identity, _ in await transfer.setIdentity(identity); return transfer },
      startLease: { expire in lease.expiration = expire; return { lease.expiration = nil } },
      record: { lease.events.append($0) }, galleryDeadline: galleryDeadline,
      makePairStore: { pairRoot.map { .init(root: $0) } ?? .init() })
    probe.sceneChanged(.active)
  }

  var leaseHeld: Bool { lease.expiration != nil }
  var events: [ManualWiFiEvent] { lease.events }
  func expireLease(_ reason: ManualWiFiProbe.LeaseExpiration) { lease.expiration?(reason) }

  @MainActor
  final class SavedFinder {
    var beforeReturn: FixtureBarrier?

    func find(_ saved: [SavedCamera]) async throws -> ManualPairedCameraMatches {
      await beforeReturn?.wait()
      var results = ManualPairedCameraMatches(saved: saved)
      if let camera = saved.first {
        results.receive(peripheralID: camera.peripheralID, advertisement: [
          CBAdvertisementDataServiceUUIDsKey: [ManualPairedCameraMatches.service],
          CBAdvertisementDataManufacturerDataKey: Data([0xd8, 0x04, 0, 0, 0, 0, 0, 0]),
          CBAdvertisementDataIsConnectable: true
        ])
      }
      return results
    }
  }

  actor Bluetooth: BluetoothGateway {
    private var selected: SavedCamera?
    private var activationBarrier: FixtureBarrier?
    private var activationFailure: WirelessFailure?
    private var disconnectBarrier: FixtureBarrier?
    private(set) var disconnectCount = 0
    private(set) var activationCount = 0
    private(set) var discoverCount = 0
    private(set) var reconnectCount = 0

    func holdActivation(_ barrier: FixtureBarrier, thenThrow failure: WirelessFailure? = nil) {
      activationBarrier = barrier
      activationFailure = failure
    }

    func holdDisconnect(_ barrier: FixtureBarrier) { disconnectBarrier = barrier }

    func discover() async throws -> AsyncThrowingStream<[DiscoveredCamera], Error> {
      discoverCount += 1
      let camera = DiscoveredCamera(peripheralID: UUID(), advertisedModelHint: .xt5, displayName: "New fixture X-T5")
      return AsyncThrowingStream {
        $0.yield([camera])
        $0.finish()
      }
    }

    func pair(_ camera: DiscoveredCamera) async throws -> SavedCamera {
      let paired = SavedCamera(id: WirelessCameraID(), peripheralID: camera.peripheralID,
        model: .xt5, displayName: camera.displayName)
      selected = paired
      return paired
    }

    func reconnect(_ camera: SavedCamera, allowPermissionPrompt: Bool) async throws {
      reconnectCount += 1
      selected = camera
    }

    func identity(for id: WirelessCameraID) async throws -> WirelessIdentity {
      guard selected?.id == id else { throw WirelessFailure.peerMismatch }
      return WirelessIdentity(cameraID: id, model: .xt5, firmware: "04.31")
    }

    func activateWiFi(for id: WirelessCameraID) async throws -> CameraNetwork {
      guard selected?.id == id else { throw WirelessFailure.peerMismatch }
      activationCount += 1
      await activationBarrier?.wait()
      if let activationFailure { throw activationFailure }
      return CameraNetwork(ssid: "fixture-network", security: .wpaPersonal,
        credential: CameraCredentialReference(cameraID: id, version: UUID()), isHidden: true)
    }

    func events() async -> AsyncStream<BluetoothGatewayEvent> { AsyncStream { $0.finish() } }

    func disconnect() async {
      disconnectCount += 1
      await disconnectBarrier?.wait()
      selected = nil
    }
  }

  actor Transfer: XAppGalleryDiagnostic {
    enum Action: Equatable { case open, countPhotos, listPhotos, download(WirelessObjectFormat), close }

    private var identity: WirelessIdentity?
    private let withoutDeviceInfo: Bool
    private let jpegOnly: Bool
    private var galleryFiles: [WirelessObjectDescriptor: Data] = [:]
    private(set) var actions: [Action] = []
    private var galleryBarrier: FixtureBarrier?
    private var galleryDelay: Duration?
    private var holdGalleryClose = false
    private var galleryCloseError: PTPError?
    private var closingGallery: AsyncStream<Void>.Continuation?
    private var confirmGalleryAbort: CheckedContinuation<Void, Never>?
    private var galleryAborted = false
    private(set) var galleryAbortCount = 0

    init(withoutDeviceInfo: Bool, jpegOnly: Bool) {
      self.withoutDeviceInfo = withoutDeviceInfo
      self.jpegOnly = jpegOnly
    }

    func setGalleryFiles(_ files: [WirelessObjectDescriptor: Data]) { galleryFiles = files }

    func setIdentity(_ identity: WirelessIdentity) { self.identity = identity }

    func checkConnection() throws -> XAppConnectionDiagnosticResult {
      actions.append(.open)
      guard let identity else { throw WirelessFailure.peerMismatch }
      return withoutDeviceInfo ? .respondingWithoutDeviceInfo : .identified(identity)
    }

    func holdGallery(_ barrier: FixtureBarrier) { galleryBarrier = barrier }
    func delayGallery(_ delay: Duration) { galleryDelay = delay }

    func checkPhotoCounts() -> XAppPhotoCountResult {
      actions.append(.countPhotos)
      let count = galleryFiles.isEmpty ? (jpegOnly ? 40 : 2) : galleryFiles.count
      return .init(cards: [.init(slot: 1, totalHandles: count), .init(slot: 2, totalHandles: nil)])
    }

    func listCameraPhotos() async throws -> XAppGalleryDiagnosticResult {
      actions.append(.listPhotos)
      if let galleryDelay { try await Task.sleep(for: galleryDelay) }
      await galleryBarrier?.wait()
      let files = if !galleryFiles.isEmpty {
        galleryFiles.keys.sorted { $0.handle < $1.handle }.map {
          XAppGalleryDiagnosticResult.Sample(filename: $0.filename, format: $0.format, byteLength: $0.byteLength)
        }
      } else if jpegOnly {
        (1...40).map {
          XAppGalleryDiagnosticResult.Sample(filename: "FIXTURE\($0).JPG", format: .jpeg, byteLength: 15_000)
        }
      } else {
        [
          XAppGalleryDiagnosticResult.Sample(filename: "FIXTURE.JPG", format: .jpeg, byteLength: 15_000),
          XAppGalleryDiagnosticResult.Sample(filename: "FIXTURE.RAF", format: .raf, byteLength: 30_000)
        ]
      }
      return .init(wifiIdentityAvailable: !withoutDeviceInfo, cards: [
        .init(slot: 1, totalHandles: files.count, samples: files),
        .init(slot: 2, totalHandles: nil, samples: [])
      ])
    }

    func scannedPairCandidates() -> [WirelessObjectDescriptor] { Array(galleryFiles.keys) }

    func downloadGalleryCandidate(
      _ object: WirelessObjectDescriptor, to sink: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> XAppOriginalControlObservation {
      guard let bytes = galleryFiles[object] else { throw WirelessFailure.objectChanged }
      actions.append(.download(object.format))
      let midpoint = bytes.count / 2
      try await sink(Data(bytes.prefix(midpoint)))
      try await sink(Data(bytes.dropFirst(midpoint)))
      return .reported(2)
    }

    func holdGalleryClose(entered: AsyncStream<Void>.Continuation) {
      holdGalleryClose = true
      closingGallery = entered
    }

    func abortGallery() {
      releaseHeldGalleryCloseForTest()
      galleryAbortCount += 1
    }

    func releaseHeldGalleryCloseForTest() {

      galleryAborted = true
      confirmGalleryAbort?.resume()
      confirmGalleryAbort = nil
    }

    func failGalleryClose(_ error: PTPError) { galleryCloseError = error }

    func close() async throws {
      actions.append(.close)
      if let galleryCloseError { throw galleryCloseError }
      guard holdGalleryClose else { return }
      closingGallery?.yield()
      closingGallery?.finish()
      closingGallery = nil
      if !galleryAborted {
        await withCheckedContinuation { confirmGalleryAbort = $0 }
      }
    }

  }
}
#endif
