import Foundation
import FujiCameraCore
import Darwin

struct PhotoPairAssetState: Codable, Sendable, Equatable {
    var assetID: String
    var modificationDate: Date?
    let captureDate: Date?
    let location: PhotoLocation?
    let isFavorite: Bool
    let isHidden: Bool
    var caption: String?
    let rating: Int
    let keywords: [String]
    let albumIDs: [String]
    var albumPositions: [String: Int] = [:]

    func hasSameMetadata(as other: Self) -> Bool {
        captureDate == other.captureDate && location == other.location && isFavorite == other.isFavorite &&
        isHidden == other.isHidden && caption == other.caption && rating == other.rating &&
        keywords == other.keywords && albumIDs == other.albumIDs && albumPositions == other.albumPositions
    }
    /// Creation inserts the new pair immediately before the old asset in each album.
    func afterPairInsertion() -> Self {
        var value = self
        value.albumPositions = albumPositions.mapValues { $0 + 1 }
        return value
    }
}

struct PhotoPairVerified: Codable, Sendable, Equatable {
    let source: PhotoSource
    let state: PhotoPairAssetState
}

struct PhotoPairIntent: Codable, Sendable, Equatable {
    enum Phase: String, Codable, Sendable { case prepared, submitted, rejected, created, verified, removed }
    let operationID: UUID
    let source: PhotoSource
    let originalState: PhotoPairAssetState
    let rawSHA256: String
    let jpegSHA256: String
    let width: Int
    let height: Int
    let orientation: Int
    var phase: Phase = .prepared
    var pairedAssetID: String?
    var verified: PhotoPairVerified?
    var removalOriginalState: PhotoPairAssetState?
    var batchID: UUID?
    var batchSequence: Int?
    var removalBatchSequence: Int?
    var filename: String { "FujiStudio-\(operationID.uuidString).jpg" }
}

/// Small durable intents; image bytes remain owned by Photos and the export pin.
actor PhotoPairJournal {
    private let directory: URL
    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("FujiStudio/pair-replacements", isDirectory: true)) {
        self.directory = directory
    }
    func intent(_ id: UUID) throws -> PhotoPairIntent? {
        let file = url(id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(PhotoPairIntent.self, from: Data(contentsOf: file))
    }
    func all() throws -> [PhotoPairIntent] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { file in
                let intent = try JSONDecoder().decode(PhotoPairIntent.self, from: Data(contentsOf: file))
                guard file.lastPathComponent == url(intent.operationID).lastPathComponent else { throw ResourceError.resourceChanged }
                return intent
            }
    }
    func store(_ intent: PhotoPairIntent) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = url(intent.operationID)
        try JSONEncoder().encode(intent).write(to: file, options: .atomic)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }
    private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}
