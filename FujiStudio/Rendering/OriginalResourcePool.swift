import Foundation

/// One permit spans retrieval, verification and the caller's complete awaited use. Waiters have
/// no file. Neither cancellation nor actor reentrancy releases an active lease prematurely.
actor OriginalResourcePool {
    typealias Prepare = @Sendable (LocalResource) throws -> PreparedRAW
    private let reader: any PhotoLibraryReading
    private let gate: SerialCameraGate
    private let prepare: Prepare
    init(reader: any PhotoLibraryReading, gate: SerialCameraGate = SerialCameraGate(), prepare: @escaping Prepare = { try RAFMetadataReader().prepare($0) }) {
        self.reader = reader; self.gate = gate; self.prepare = prepare
    }
    func withPreparedRAW<T: Sendable>(source: PhotoSource, operation: @Sendable (PreparedRAW) async throws -> T) async throws -> T {
        try await gate.withExclusiveAccess {
            try Task.checkCancellation()
            let token = source.originalResources.raf
            guard token.assetID == source.id, token.sourceRevision == source.resourceRevision,
                  token.format == .raf, token.role != .adjusted else { throw ResourceError.resourceChanged }
            let resource = try await self.reader.materialize(token, progress: { _ in })
            defer { try? FileManager.default.removeItem(at: resource.fileURL) }
            try Task.checkCancellation()
            guard resource.token == token else { throw ResourceError.resourceChanged }
            let raw = try self.prepare(resource)
            guard raw.sourceID == source.id, raw.sourceRevision == source.resourceRevision,
                  raw.fileURL == resource.fileURL else { throw ResourceError.resourceChanged }
            return try await operation(raw)
        }
    }
}
