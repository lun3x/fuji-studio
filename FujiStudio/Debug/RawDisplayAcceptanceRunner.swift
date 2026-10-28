import FujiCameraCore
#if DEBUG
import Foundation
import Observation
import ImageIO

/// Read-only retained binding; no bank import or camera support promotion is involved.
struct RetainedRAWSource: Sendable {
    let raw: PreparedRAW
    let rafRole: ResourceRole
    let jpegRole: ResourceRole?
    let originalFilename: String
    let manifestURL: URL, protocolURL: URL
}

enum RawDisplayAcceptanceOutcome: String, Codable {
    case preparing, inputUnavailable, rawDisplayUnavailable, cancelled, rawDisplayAvailable
}

struct RawDisplayAcceptanceEvidence: Codable {
    var complete = false
    var outcome: RawDisplayAcceptanceOutcome = .preparing
    var materializedOriginals = 0
    var recordedWidth: Int?, recordedHeight: Int?, recordedOrientation: Int?
    var displayWidth: Int?, displayHeight: Int?, displayOrientation: Int?, displayBytes: Int?
}

/// DEBUG local decoder proof only. Its dependencies cannot upload, import banks, or save to Photos.
@MainActor @Observable final class RawDisplayAcceptanceRunner {
    typealias Load = @Sendable (URL) throws -> RetainedRAWSource
    var status = "RAW display acceptance has not run"
    private let directory: URL?
    private let reader: any PhotoLibraryReading
    private let pool: OriginalResourcePool
    private let load: Load
    private var didRun = false
    init(directory: URL? = nil, reader: any PhotoLibraryReading = PhotoLibraryReader(), pool: OriginalResourcePool? = nil,
         load: @escaping Load = { try RetainedProductionAcceptanceInputs.loadSource(root: $0.appendingPathComponent("xt5-paired-baseline-private"), paired: true) }) {
        self.directory = directory; self.reader = reader; self.load = load
        self.pool = pool ?? OriginalResourcePool(reader: reader)
    }

    func runIfRequested(arguments: [String]) async {
        let flag = "--raw-display-acceptance-probe"
        guard arguments.contains(flag), !didRun,
              !arguments.contains(where: { $0 != flag && $0.hasPrefix("--") && $0.hasSuffix("-probe") }) else { return }
        didRun = true
        var evidence = RawDisplayAcceptanceEvidence()
        var documents: URL?
        do {
            let root = try directory ?? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            documents = root
            let run = root.appendingPathComponent("raw-display-acceptance-private/runs").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            try save(evidence, to: root)
            // The potentially large retained checksum runs off the main actor. It creates no RAF.
            let load = load
            let loading = Task.detached { try load(root) }
            let retained = try await withTaskCancellationHandler { try await loading.value } onCancel: { loading.cancel() }
            let source = try await reader.source(id: retained.raw.sourceID)
            guard source.id == retained.raw.sourceID, source.resourceRevision == retained.raw.sourceRevision,
                  source.originalResources.raf.assetID == source.id,
                  source.originalResources.raf.sourceRevision == source.resourceRevision,
                  source.originalResources.raf.format == .raf,
                  source.originalResources.raf.role == retained.rafRole, retained.rafRole != .adjusted,
                  source.originalResources.raf.originalFilename == retained.originalFilename,
                  let jpeg = source.originalResources.jpeg, jpeg.format == .jpeg,
                  jpeg.assetID == source.id, jpeg.sourceRevision == source.resourceRevision,
                  jpeg.role == retained.jpegRole, jpeg.role != .adjusted, jpeg.role != retained.rafRole else { throw ResourceError.resourceChanged }
            // This folder is private device evidence. Public status contains no IDs, hashes or paths.
            try FileManager.default.copyItem(at: retained.manifestURL, to: run.appendingPathComponent("retained-source-manifest.json"))
            try FileManager.default.copyItem(at: retained.protocolURL, to: run.appendingPathComponent("retained-protocol-manifest.json"))
            struct Binding: Encodable { let source: PhotoSource; let retainedSHA256: String; let retainedPath: String }
            try JSONEncoder().encode(Binding(source: source, retainedSHA256: retained.raw.sha256, retainedPath: retained.raw.fileURL.path))
                .write(to: run.appendingPathComponent("live-source-binding.json"), options: [.atomic, .completeFileProtection])
            let m = retained.raw.metadata
            evidence.recordedWidth = m.recordedGeometry.width; evidence.recordedHeight = m.recordedGeometry.height; evidence.recordedOrientation = m.orientation
            let renderer = try RawDisplayRenderer(directory: run)
            let display = try await pool.withPreparedRAW(source: source) { raw in
                guard raw.sha256 == retained.raw.sha256, raw.metadata == retained.raw.metadata else { throw ResourceError.resourceChanged }
                return try await renderer.render(raw)
            }
            evidence.materializedOriginals = 1
            guard let decoded = CGImageSourceCreateWithURL(display as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [String: Any],
                  let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight as String] as? Int else { throw RawDisplayError.unavailable }
            evidence.displayWidth = width; evidence.displayHeight = height
            evidence.displayOrientation = properties[kCGImagePropertyOrientation as String] as? Int ?? 1
            evidence.displayBytes = try display.resourceValues(forKeys: [.fileSizeKey]).fileSize
            try FileManager.default.moveItem(at: display, to: run.appendingPathComponent("raw-display.JPG"))
            evidence.complete = true; evidence.outcome = .rawDisplayAvailable
        } catch is RawDisplayError {
            evidence.materializedOriginals = 1
            evidence.outcome = .rawDisplayUnavailable
        } catch is CancellationError { evidence.outcome = .cancelled }
        catch { evidence.outcome = .inputUnavailable }
        if let documents {
            do { try save(evidence, to: documents) }
            catch { status = "RAW display evidence could not be written"; return }
        }
        status = evidence.complete ? "RAW display available: \(evidence.displayWidth ?? 0) × \(evidence.displayHeight ?? 0)" : evidence.outcome.rawValue
    }

    private func save(_ evidence: RawDisplayAcceptanceEvidence, to documents: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: documents.appendingPathComponent("raw-display-acceptance-evidence.json"), options: [.atomic, .completeFileProtection])
    }
}
#endif
