import FujiCameraCore
import Foundation

struct OriginalIdentity: Sendable, Hashable {
    let sourceID: SourceID, revision: String
    init(_ source: PhotoSource) { sourceID = source.id; revision = source.resourceRevision }
}

/// One permit spans retrieval, verification and the caller's complete awaited use. Waiters have
/// no file. Neither cancellation nor actor reentrancy releases an active lease prematurely.
actor OriginalResourcePool {
    typealias Prepare = @Sendable (LocalResource) throws -> PreparedRAW
    private let reader: any PhotoLibraryReading
    private let gate: SerialCameraGate
    private let prepare: Prepare
    private var detected: [OriginalIdentity: RAWCompatibility] = [:]
    private var metadata: [OriginalIdentity: RAWMetadata] = [:]
    private var observers: [UUID: AsyncStream<[OriginalIdentity: RAWCompatibility]>.Continuation] = [:]
    init(reader: any PhotoLibraryReading, gate: SerialCameraGate = SerialCameraGate(), prepare: @escaping Prepare = { try RAFMetadataReader().prepare($0) }) {
        self.reader = reader; self.gate = gate; self.prepare = prepare
    }
    func compatibilityChanges() -> AsyncStream<[OriginalIdentity: RAWCompatibility]> {
        let id = UUID(), pair = AsyncStream<[OriginalIdentity: RAWCompatibility]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = pair.continuation
        pair.continuation.yield(detected)
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return pair.stream
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    func compatibility(for source: PhotoSource) -> RAWCompatibility { detected[OriginalIdentity(source)] ?? source.compatibility }
    /// Camera-specific admission is separate from model recognition used by original viewing.
    func assess(source: PhotoSource, for support: VerifiedCameraSupport) async throws -> RAWCompatibility {
        try Task.checkCancellation()
        let token = source.originalResources.raf
        guard token.assetID == source.id, token.sourceRevision == source.resourceRevision,
              token.format == .raf, token.role != .adjusted else { throw ResourceError.resourceChanged }
        if let metadata = metadata[OriginalIdentity(source)] {
            return SourceCompatibility.assess(metadata, for: support)
        }
        do {
            return try await withPreparedRAW(source: source) { SourceCompatibility.assess($0.metadata, for: support) }
        } catch ResourceError.incompatibleCamera(let model) {
            return .incompatible(model: model)
        }
    }
    private func remember(_ raw: PreparedRAW, source: PhotoSource) { metadata[OriginalIdentity(source)] = raw.metadata }
    private func record(_ compatibility: RAWCompatibility, source: PhotoSource) {
        let identity = OriginalIdentity(source)
        guard detected[identity] != compatibility else { return }
        detected[identity] = compatibility
        observers.values.forEach { $0.yield(detected) }
    }
    /// Revalidate queued work only after the resource permit is acquired, before any download.
    func withPreparedRAW<T: Sendable>(source: PhotoSource, beforeMaterialize: @Sendable () async throws -> Void = {},
        progress: @escaping @Sendable (Double) -> Void = { _ in }, operation: @Sendable (PreparedRAW) async throws -> T) async throws -> T {
        try await gate.withExclusiveAccess {
            try Task.checkCancellation()
            try await beforeMaterialize()
            try Task.checkCancellation()
            if case .incompatible(let model) = await self.compatibility(for: source) { throw ResourceError.incompatibleCamera(model) }
            let token = source.originalResources.raf
            guard token.assetID == source.id, token.sourceRevision == source.resourceRevision,
                  token.format == .raf, token.role != .adjusted else { throw ResourceError.resourceChanged }
            let resource = try await self.reader.materialize(token, progress: progress)
            defer { try? FileManager.default.removeItem(at: resource.fileURL) }
            try Task.checkCancellation()
            guard resource.token == token else { throw ResourceError.resourceChanged }
            let raw: PreparedRAW
            do { raw = try self.prepare(resource) }
            catch ResourceError.incompatibleCamera(let model) {
                await self.record(.incompatible(model: model), source: source)
                throw ResourceError.incompatibleCamera(model)
            }
            guard raw.sourceID == source.id, raw.sourceRevision == source.resourceRevision,
                  raw.fileURL == resource.fileURL else { throw ResourceError.resourceChanged }
            await self.remember(raw, source: source)
            let compatibility=SourceCompatibility.detected(raw.metadata)
            await self.record(compatibility, source: source)
            if case .incompatible(let model)=compatibility { throw ResourceError.incompatibleCamera(model) }
            return try await operation(raw)
        }
    }
}
