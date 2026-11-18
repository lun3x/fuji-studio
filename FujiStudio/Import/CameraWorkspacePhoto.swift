import Foundation
import FujiCameraCore
import UIKit

extension WirelessObjectDescriptor {
    var trayID: SourceID { "camera-\(sessionID)-\(storageID)-\(handle)" }
}

extension CameraCapture {
    var photoSource: PhotoSource? {
        guard let raw else { return nil }
        let id = raw.trayID
        func resource(_ object: WirelessObjectDescriptor) -> ResourceToken {
            let isRaw = object.format == .raf
            return ResourceToken(assetID: id, role: isRaw && jpeg != nil ? .alternateOriginal : .primaryOriginal,
                contentTypeIdentifier: isRaw ? "com.fuji.raw-image" : "public.jpeg", format: isRaw ? .raf : .jpeg,
                originalFilename: object.filename, discriminator: object.trayID, byteCount: Int64(exactly: object.byteLength))
        }
        return PhotoSource(id: id, originalResources: .init(raf: resource(raw), jpeg: jpeg.map(resource)),
                           captureDate: timestamp?.xT5Date, resourceRevision: id)
    }
}

enum CameraViewerOriginal {
    static func load(_ object: WirelessObjectDescriptor, session: any WirelessTransferSession) async throws -> ViewerFile {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = try ImportStagingStore(root: directory)
        try staging.preflight(stagingByteLengths: [object.byteLength], photoCopyByteLengths: [])
        let original = try await staging.write(object: object, session: session)
        let url = try staging.fileURL(for: original)
        let geometry: ImageGeometry
        let image: URL
        switch object.format {
        case .raf:
            let metadata = try RAFMetadataReader().metadata(inFileAt: url).metadata
            let raw = PreparedRAW(fileURL: url, sha256: original.sha256, sourceID: object.trayID,
                                  sourceRevision: object.trayID, metadata: metadata)
            let renderer = try RawDisplayRenderer(directory: directory)
            image = try await renderer.render(raw)
            geometry = .raw(metadata)
        case .jpeg:
            geometry = try ImageGeometry.read(url)
            image = url
        default: throw ViewerError.invalidVersion
        }
        return ViewerFile(lease: try DisplayFileLease.copy(from: image, geometry: geometry), geometry: geometry)
    }
}

@MainActor
final class CameraGridThumbnails: GridThumbnailProviding {
    let browser: CameraBrowserModel
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(browser: CameraBrowserModel) { self.browser = browser }

    func request(sourceID: SourceID, pixelSize: CGSize, completion: @escaping @MainActor (UIImage?) -> Void) -> UUID {
        let token = UUID()
        tasks[token] = Task {
            defer { tasks[token] = nil }
            guard let capture = browser.capture(for: sourceID), let object = capture.thumbnailObject,
                  let data = await browser.thumbnail(for: capture),
                  !Task.isCancelled else { return }
            let thumbnail = await Task.detached { CameraThumbnail.decode(data, object: object) }.value
            guard !Task.isCancelled else { return }
            completion(thumbnail.map { UIImage(cgImage: $0.image) })
        }
        return token
    }

    func cancel(_ token: UUID) { tasks.removeValue(forKey: token)?.cancel() }
    // CameraBrowserModel caches visible previews. Speculative PTP requests delay the inventory.
    func cache(sourceIDs: [SourceID], pixelSize: CGSize) {}
    func invalidate(sourceIDs: Set<SourceID>) {}
}
