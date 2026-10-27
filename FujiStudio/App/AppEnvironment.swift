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
    let camera: any CameraServing
    let catalog: any CatalogStoring
    let originals: OriginalResourcePool
    let preview: PreviewCoordinator
    let resolver: VersionImageResolver
    let exports: ExportCoordinator
    let cache: FileRenderCache
    let thumbnails: any GridThumbnailProviding
    let platform: any AppPlatform
    let jpegDetail = JPEGDetailRenderer()

    static func live() async throws -> AppEnvironment {
        // SwiftData's executor must be created away from the UI actor; cache scans and journal
        // initialization also stay here. Only native ImageCapture and thumbnail UI belong on main.
        let storage = try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("FujiStudio", isDirectory: true)
            let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("FujiStudio", isDirectory: true)
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            let catalog = try SwiftDataCatalog(storeURL: support.appendingPathComponent("catalog.store"))
            let cache = try FileRenderCache(directory: caches.appendingPathComponent("renders"), pinnedDirectory: support.appendingPathComponent("export-pins"))
            let journal = try CameraOperationJournal(directory: support.appendingPathComponent("camera-journal"))
            try ResourceFileTransfer.prepareDirectory()
            let display = caches.appendingPathComponent("raw-display", isDirectory: true)
            // Dedicated disposable fit/detail output, before constructing the sole renderer.
            // Current viewer leases live in a different transient root; durable pins are untouched.
            try? fm.removeItem(at: display)
            let renderer = try RawDisplayRenderer(directory: display)
            return (catalog, cache, journal, renderer)
        }.value
        let reader = PhotoLibraryReader()
        let camera = XT5CameraService(session: ImageCaptureSessionTransport(), journal: storage.2)
        let pool = OriginalResourcePool(reader: reader)
        let scheduler = CameraWorkScheduler()
        let resolver = VersionImageResolver(library: reader, catalog: storage.0, pool: pool, rawRenderer: storage.3, cache: storage.1)
        let preview = PreviewCoordinator(pool: pool, camera: camera, scheduler: scheduler, cache: storage.1, rawRenderer: storage.3,
            storedDisplay: { source, version, progress in try await resolver.resolve(source: source, version: version, progress: progress).lease })
        let exports = ExportCoordinator(reader: reader, camera: camera, catalog: storage.0, writer: PhotoLibraryWriter(), pool: pool, cache: storage.1, scheduler: scheduler)
        return AppEnvironment(reader: reader, camera: camera, catalog: storage.0, originals: pool, preview: preview, resolver: resolver,
            exports: exports, cache: storage.1, thumbnails: ThumbnailProvider(), platform: NativeAppPlatform())
    }
}
