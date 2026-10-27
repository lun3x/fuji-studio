import SwiftUI
import ImageIO
import CoreImage

/// Authoritative recorded/encoded pixel geometry, independent of the bounded fit-file size.
/// UIKit inspection coordinates are upright with a top-left origin.
struct ImageGeometry: Sendable, Equatable {
    let encoded: PixelSize
    let orientation: Int
    /// RAW container pixels can include margins outside the recorded output crop.
    var recorded: PixelSize? = nil
    /// Top-left origin of the recorded crop inside the encoded RAW container.
    var recordedOrigin: CGPoint? = nil
    var upright: PixelSize {
        let pixels = recorded ?? encoded
        return (5...8).contains(orientation) ? PixelSize(width: pixels.height, height: pixels.width) : pixels
    }
    var isValid: Bool {
        guard encoded.width > 0, encoded.height > 0, (1...8).contains(orientation) else { return false }
        if let recorded {
            guard recorded.width > 0, recorded.height > 0, recorded.width <= encoded.width, recorded.height <= encoded.height else { return false }
        }
        if let origin = recordedOrigin {
            guard let recorded, origin.x.isFinite, origin.y.isFinite, origin.x >= 0, origin.y >= 0,
                  origin.x + CGFloat(recorded.width) <= CGFloat(encoded.width),
                  origin.y + CGFloat(recorded.height) <= CGFloat(encoded.height) else { return false }
        }
        return true
    }
    static func raw(_ metadata: RAWMetadata) -> ImageGeometry {
        ImageGeometry(encoded: metadata.containerGeometry, orientation: metadata.orientation,
            recorded: metadata.recordedGeometry, recordedOrigin: CGPoint(x: metadata.cropLeft, y: metadata.cropTop))
    }
    func matchesInspection(_ other: ImageGeometry) -> Bool { isValid && other.isValid && upright == other.upright }
    static func bottomLeftRegion(_ topLeft: CGRect) -> CGRect {
        CGRect(x: topLeft.minX, y: 1 - topLeft.maxY, width: topLeft.width, height: topLeft.height)
    }
    static func read(_ url: URL) throws -> ImageGeometry {
        guard let image = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any],
              let width = p[kCGImagePropertyPixelWidth as String] as? Int,
              let height = p[kCGImagePropertyPixelHeight as String] as? Int else { throw ViewerError.invalidImage }
        let value = ImageGeometry(encoded: PixelSize(width: width, height: height), orientation: p[kCGImagePropertyOrientation as String] as? Int ?? 1)
        guard value.isValid else { throw ViewerError.invalidImage }; return value
    }
}

/// A separate transient file, never a durable camera/export journal pin. Immutable Sendable
/// references keep in-flight decoding alive; the last owner removes only its UUID directory.
final class DisplayFileLease: Sendable, Equatable {
    let fileURL: URL
    /// Logical source geometry. Fit/detail file pixels may already be cropped, scaled and upright.
    let geometry: ImageGeometry?
    private let directory: URL
    private static let root: URL = {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FujiStudioViewer", isDirectory: true)
        // These files are transient and owned exclusively by this process. Reclaim abandoned
        // display copies from an earlier app launch, never cache entries or export journals.
        try? FileManager.default.removeItem(at: root)
        return root
    }()
    private init(fileURL: URL, directory: URL, geometry: ImageGeometry?) {
        self.fileURL = fileURL; self.directory = directory; self.geometry = geometry
    }
    static func copy(from source: URL, geometry: ImageGeometry? = nil) throws -> DisplayFileLease {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("image.JPG")
            try FileManager.default.copyItem(at: source, to: url)
            return DisplayFileLease(fileURL: url, directory: directory, geometry: geometry)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw RenderCacheError.storage
        }
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    static func == (lhs: DisplayFileLease, rhs: DisplayFileLease) -> Bool { lhs === rhs }
}

enum ViewerError: Error, Sendable, Equatable {
    case unavailable(AssetAvailability), invalidVersion, invalidImage
}
struct ViewerFile: Sendable {
    let lease: DisplayFileLease
    let geometry: ImageGeometry
}

/// Inject the same pool/renderer used by PreviewCoordinator. No Photos writes or retained RAW.
/// Each returned lease is owned by the current viewer/operation; callers discard stale results.
actor VersionImageResolver {
    private let library: any PhotoLibraryReading
    private let catalog: any CatalogStoring
    private let pool: OriginalResourcePool
    private let rawRenderer: RawDisplayRenderer
    private let cache: FileRenderCache
    init(library: any PhotoLibraryReading, catalog: any CatalogStoring, pool: OriginalResourcePool,
         rawRenderer: RawDisplayRenderer, cache: FileRenderCache) {
        self.library = library; self.catalog = catalog; self.pool = pool; self.rawRenderer = rawRenderer; self.cache = cache
    }
    func resolve(source: PhotoSource, version: VersionID, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> ViewerFile {
        switch version {
        case .raw:
            return try await pool.withPreparedRAW(source: source) { raw in
                let url = try await self.rawRenderer.render(raw)
                let geometry = ImageGeometry.raw(raw.metadata)
                return ViewerFile(lease: try DisplayFileLease.copy(from: url, geometry: geometry), geometry: geometry)
            }
        case .preview(let key):
            guard key.sourceID == source.id, key.sourceRevision == source.resourceRevision else { throw ViewerError.invalidVersion }
            return ViewerFile(lease: try await cache.copyForDisplay(key),
                geometry: ImageGeometry(encoded: PixelSize(width: key.width, height: key.height), orientation: key.orientation))
        case .cameraJPEG:
            guard let token = source.originalResources.jpeg, token.assetID == source.id, token.role != .adjusted,
                  token.format == .jpeg else { throw ViewerError.invalidVersion }
            return try await materialize(token, geometry: nil, progress: progress)
        case .saved(let id):
            guard let version = try await catalog.versions(sourceID: source.id).first(where: { $0.id == id && $0.sourceID == source.id }) else { throw ViewerError.invalidVersion }
            guard version.availability == .available else { throw ViewerError.unavailable(version.availability) }
            let originals = try await library.resources(assetID: version.outputAssetID).filter {
                $0.assetID == version.outputAssetID && $0.format == .jpeg && $0.role != .adjusted
            }
            guard originals.count == 1, let token = originals.first else { throw ResourceError.ambiguousOriginalJPEG }
            return try await materialize(token, geometry: ImageGeometry(encoded: PixelSize(width: version.width, height: version.height), orientation: version.orientation), progress: progress)
        }
    }
    private func materialize(_ token: ResourceToken, geometry: ImageGeometry?, progress: @escaping @Sendable (Double) -> Void) async throws -> ViewerFile {
        let local = try await library.materialize(token, progress: progress)
        defer { try? FileManager.default.removeItem(at: local.fileURL) }
        try Task.checkCancellation()
        guard local.token == token else { throw ResourceError.resourceChanged }
        let actual = try ImageGeometry.read(local.fileURL)
        if let geometry, geometry != actual { throw ViewerError.invalidImage }
        return ViewerFile(lease: try DisplayFileLease.copy(from: local.fileURL, geometry: geometry ?? actual), geometry: geometry ?? actual)
    }
    func rawDetail(source: PhotoSource, topLeftRegion: CGRect, maximumDimension: Int) async throws -> DisplayFileLease {
        try await pool.withPreparedRAW(source: source) { raw in
            let url = try await self.rawRenderer.renderDetail(raw, region: ImageGeometry.bottomLeftRegion(topLeftRegion), maximumDimension: maximumDimension)
            return try DisplayFileLease.copy(from: url)
        }
    }
}

/// Serial JPEG region rendering from the original full-resolution file, never a gallery thumbnail.
actor JPEGDetailRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    func detail(file: DisplayFileLease, topLeftRegion: CGRect, maximumDimension: Int) throws -> DisplayFileLease {
        try Task.checkCancellation()
        return try autoreleasepool {
            defer { context.clearCaches() }
            guard let image = CIImage(contentsOf: file.fileURL, options: [.applyOrientationProperty: true]) else { throw ViewerError.invalidImage }
            let r = ImageGeometry.bottomLeftRegion(topLeftRegion), bounds = image.extent
            let crop = CGRect(x: bounds.minX + r.minX * bounds.width, y: bounds.minY + r.minY * bounds.height,
                width: r.width * bounds.width, height: r.height * bounds.height).intersection(bounds)
            guard !crop.isEmpty, maximumDimension > 0 else { throw ViewerError.invalidImage }
            let scale = min(1, CGFloat(maximumDimension) / max(crop.width, crop.height))
            let output = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("viewer-detail-\(UUID().uuidString).JPG")
            defer { try? FileManager.default.removeItem(at: url) }
            try context.writeJPEGRepresentation(of: output, to: url, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:])
            try Task.checkCancellation()
            return try DisplayFileLease.copy(from: url)
        }
    }
}

struct PhotoViewer: View {
    let sourceID: SourceID
    let version: VersionID
    let imageURL: URL?
    let geometry: ImageGeometry?
    let onVersionSelected: (VersionID) -> Void
    var displayFile: DisplayFileLease? = nil
    var detail: ZoomPhotoView.DetailProvider? = nil
    var status: String? = nil
    @State private var control = ZoomControl()

    var body: some View {
        VStack(spacing: 8) {
            if let imageURL, let geometry, geometry.isValid {
                ZoomPhotoView(sourceID: sourceID, version: version, imageURL: imageURL, geometry: geometry,
                    displayFile: displayFile, detail: detail, control: control)
                HStack {
                    Button("Zoom out", systemImage: "minus.magnifyingglass") { control.zoomOut?() }.accessibilityIdentifier("viewer.zoomOut")
                    Button("Fit") { control.fit?() }.accessibilityIdentifier("viewer.fit")
                    Button("Zoom in", systemImage: "plus.magnifyingglass") { control.zoomIn?() }.accessibilityIdentifier("viewer.zoomIn")
                }.labelStyle(.iconOnly).buttonStyle(.bordered)
            } else {
                ContentUnavailableView {
                    Label(version == .raw ? "RAW display unavailable" : "Image unavailable", systemImage: "photo")
                } description: {
                    Text(status ?? (version == .raw ? "This RAW can still be converted by the camera." : "The original image is not currently accessible."))
                }.accessibilityElement(children: .combine).accessibilityIdentifier("viewer.unavailable")
            }
        }.onChange(of: sourceID) { _, source in control.forgetOtherSource(source) }
    }
}
