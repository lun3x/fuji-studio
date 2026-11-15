import FujiCameraCore
import SwiftUI
import Photos
import PhotosUI
import UIKit

@MainActor protocol AppPlatform: AnyObject {
    var idleTimerDisabled: Bool { get set }
    func managePhotos()
    func openSettings()
}

@MainActor final class NativeAppPlatform: AppPlatform {
    var idleTimerDisabled: Bool {
        get { UIApplication.shared.isIdleTimerDisabled }
        set { UIApplication.shared.isIdleTimerDisabled = newValue }
    }
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    func managePhotos() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        var presenter = root
        while let next = presenter.presentedViewController { presenter = next }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
    }
}

/// One composition per app. All service boundaries carry values or owned file leases.
@MainActor struct AppEnvironment {
    let reader: any PhotoLibraryReading
    let camera: ArbitratedCameraService
    let catalog: any CatalogStoring
    let originals: OriginalResourcePool
    let preview: PreviewCoordinator
    let resolver: VersionImageResolver
    let exports: ExportCoordinator
    let cache: FileRenderCache
    let thumbnails: any GridThumbnailProviding
    let platform: any AppPlatform
    let wireless: WirelessServices
    let jpegDetail = JPEGDetailRenderer()
    var cameraUseArbiter: CameraUseArbiter { camera.arbiter }
    var wirelessOwnership: some WirelessCameraOwnershipGateway {
        let preview = self.preview
        return camera.wirelessOwnership { await preview.invalidate() }
    }

    static func live(includeWireless: Bool = true) async throws -> AppEnvironment {
        // SwiftData's executor must be created away from the UI actor; cache scans and journal
        // initialization also stay here. Only native ImageCapture and thumbnail UI belong on main.
        let storage = try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("FujiStudio", isDirectory: true)
            let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("FujiStudio", isDirectory: true)
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            let catalog = try SwiftDataCatalog(storeURL: support.appendingPathComponent("catalog.store"))
            let cache = try FileRenderCache(directory: caches.appendingPathComponent("renders"), pinnedDirectory: support.appendingPathComponent("export-pins"))
            let journal = try CameraOperationJournal(directory: support.appendingPathComponent("camera-journal"), filePolicy: IOSCameraJournalFilePolicy())
            let importJournal = try ImportJournal()
            let staging = try ImportStagingStore()
            try ResourceFileTransfer.prepareDirectory()
            let display = caches.appendingPathComponent("raw-display", isDirectory: true)
            // Dedicated disposable fit/detail output, before constructing the sole renderer.
            // Current viewer leases live in a different transient root; durable pins are untouched.
            try? fm.removeItem(at: display)
            let renderer = try RawDisplayRenderer(directory: display)
            return (catalog, cache, journal, renderer, caches.appendingPathComponent("raw-metadata", isDirectory: true), importJournal, staging)
        }.value
        let reader = PhotoLibraryReader()
        let arbiter = CameraUseArbiter()
        let camera = ArbitratedCameraService(
            FujiCameraService(session: ImageCaptureSessionTransport(), journal: storage.2), arbiter: arbiter)
        let pool = OriginalResourcePool(reader: reader, metadataCacheDirectory: storage.4)
        let scheduler = CameraWorkScheduler(arbiter: arbiter)
        let resolver = VersionImageResolver(library: reader, catalog: storage.0, pool: pool, rawRenderer: storage.3, cache: storage.1)
        let preview = PreviewCoordinator(pool: pool, camera: camera, scheduler: scheduler, cache: storage.1, rawRenderer: storage.3,
            storedDisplay: { source, version, progress in try await resolver.resolve(source: source, version: version, progress: progress).lease })
        let exports = ExportCoordinator(reader: reader, camera: camera, catalog: storage.0,
            writer: PhotoLibraryWriter(pairer: PhotoLibraryPairer(reader: reader)), pool: pool, cache: storage.1, scheduler: scheduler)
        let ownership = camera.wirelessOwnership { await preview.invalidate() }
        let wireless: WirelessServices
        #if DEBUG
        if includeWireless {
            wireless = .live(journal: storage.5, staging: storage.6, ownership: ownership)
        } else {
            wireless = WirelessFixture.inactiveServices(journal: storage.5, staging: storage.6)
        }
        #else
        wireless = .live(journal: storage.5, staging: storage.6, ownership: ownership)
        #endif
        if wireless.isEnabled { try await arbiter.installBluetoothController(wireless.connection) }
        return AppEnvironment(reader: reader, camera: camera, catalog: storage.0, originals: pool, preview: preview, resolver: resolver,
            exports: exports, cache: storage.1, thumbnails: ThumbnailProvider(), platform: NativeAppPlatform(), wireless: wireless)
    }
}

@MainActor struct WirelessServices {
    let connection: WirelessConnectionCoordinator
    let browser: CameraBrowserModel
    let importer: CameraImportCoordinator
    let journal: ImportJournal
    let requestPhotosAccess: @MainActor () async -> LibraryAccess
    let isEnabled: Bool

    init(connection: WirelessConnectionCoordinator, journal: ImportJournal, staging: ImportStagingStore,
         photoGateway: any PhotoImportGateway, isEnabled: Bool = true,
         requestPhotosAccess: @escaping @MainActor () async -> LibraryAccess) {
        self.connection = connection
        self.browser = CameraBrowserModel()
        self.importer = CameraImportCoordinator(journal: journal, staging: staging, gateway: photoGateway)
        self.journal = journal
        self.requestPhotosAccess = requestPhotosAccess
        self.isEnabled = isEnabled
    }

    static func live(journal: ImportJournal, staging: ImportStagingStore,
                     ownership: some WirelessCameraOwnershipGateway) -> Self {
        let defaults = UserDefaults.standard
        let clientKey = "wireless.clientID"
        let clientID = defaults.string(forKey: clientKey).flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(clientID.uuidString, forKey: clientKey)
        let guid = withUnsafeBytes(of: clientID.uuid) { Data($0) }
        let store = KeychainCameraStore(defaults: defaults)
        let connection = WirelessConnectionCoordinator(
            bluetooth: NativeBluetoothGateway(store: store), store: store,
            wifi: NativeWiFiJoinGateway(credentials: store), ownership: ownership,
            sessionFactory: { identity, _ in
                let mode: WirelessMode = identity.model == .xt5 ? .xApp : .phone
                let channel = try await NetworkByteChannel.connect(to: .cameraHosted(mode: mode))
                let transport = WirelessPTPTransport(channel: channel)
                switch identity.model {
                case .xt5:
                    return XAppTransferAdapter.makeSession(transport: transport, expectedIdentity: identity, clientGUID: guid)
                case .xe3:
                    return PhoneTransferAdapter.makeSession(transport: transport, expectedIdentity: identity, clientGUID: guid)
                }
            },
            autoSave: NativeAutoSaveGateway(store: store, clientGUID: guid))
        return Self(connection: connection, journal: journal, staging: staging,
                    photoGateway: NativePhotoImportGateway(staging: staging),
                    requestPhotosAccess: NativePhotoImportGateway.requestReadWriteAccess)
    }
}
