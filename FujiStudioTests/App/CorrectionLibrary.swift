import Foundation
@testable import FujiStudio

/// Only the PhotoKit boundary is replaced; real pool/parser/resolver/coordinators remain composed.
actor CorrectionLibrary: PhotoLibraryReading {
    let base: FixtureLibrary
    private var rawBytes: [SourceID: Data] = [:]
    private(set) var rawMaterializations = 0
    init(base: FixtureLibrary) { self.base = base }
    func setRAW(_ id: SourceID, bytes: Data) { rawBytes[id] = bytes }
    func requestAccess() async -> LibraryAccess { await base.requestAccess() }
    func sources() async -> AsyncThrowingStream<[PhotoSource], Error> { await base.sources() }
    func allEligibleSources() async throws -> [PhotoSource] { try await base.allEligibleSources() }
    func source(id: SourceID) async throws -> PhotoSource { try await base.source(id: id) }
    func resources(assetID: String) async throws -> [ResourceToken] { try await base.resources(assetID: assetID) }
    func changes() async -> AsyncStream<LibraryChange> { await base.changes() }
    func materialize(_ resource: ResourceToken, progress: @escaping @Sendable (Double) -> Void) async throws -> LocalResource {
        if resource.format == .raf {
            rawMaterializations += 1
            if let bytes = rawBytes[resource.assetID] {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID()).RAF")
                try bytes.write(to: url)
                return LocalResource(token: resource, fileURL: url, checksum: try ResourceChecksum.sha256(url))
            }
        }
        return try await base.materialize(resource, progress: progress)
    }
}
