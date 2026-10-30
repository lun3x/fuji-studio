import FujiCameraCore
import Foundation

/// Disposable metadata only: never substitutes for full preparation's checksum validation.
/// One atomic record per asset replaces old revisions without retaining obsolete entries.
struct RAWMetadataCache: Sendable {
    let directory: URL
    private struct Record: Codable {
        let parserVersion: Int
        let token: ResourceToken
        let metadata: RAWMetadata
    }
    // Bump when structural parsing changes. Camera rules are reapplied to the stored metadata.
    private let parserVersion = 2

    func metadata(for token: ResourceToken) -> RAWMetadata? {
        guard let bytes = try? Data(contentsOf: file(for: token)),
              let record = try? JSONDecoder().decode(Record.self, from: bytes),
              record.parserVersion == parserVersion, record.token == token else { return nil }
        return record.metadata
    }

    func store(_ metadata: RAWMetadata, for token: ResourceToken) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let record = Record(parserVersion: parserVersion, token: token, metadata: metadata)
            try JSONEncoder().encode(record).write(to: file(for: token), options: .atomic)
        } catch { /* A disposable cache must not prevent a successful metadata check. */ }
    }

    private func file(for token: ResourceToken) -> URL {
        directory.appendingPathComponent(ResourceChecksum.sha256(Data(token.assetID.utf8)) + ".json")
    }
}
