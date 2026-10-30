import Foundation
import FujiCameraCore
import ImageIO

protocol PhotoPairGateway: Sendable {
    func access() async -> LibraryAccess
    func state(assetID: String) async throws -> PhotoPairAssetState?
    func createPair(intent: PhotoPairIntent, rawURL: URL, jpegURL: URL,
                    onPlaceholder: @escaping @Sendable (String) -> Void) async throws -> String
    func matchingAssets(filename: String) async throws -> [String]
    func removeOriginal(intent: PhotoPairIntent, verified: PhotoPairVerified) async throws
}

struct PhotoLibraryPairer: Sendable {
    let reader: any PhotoLibraryReading
    let gateway: any PhotoPairGateway
    let journal: PhotoPairJournal

    init(reader: any PhotoLibraryReading = PhotoLibraryReader(), gateway: any PhotoPairGateway = NativePhotoPairGateway(),
         journal: PhotoPairJournal = PhotoPairJournal()) {
        self.reader = reader; self.gateway = gateway; self.journal = journal
    }

    func saveJPEG(_ request: PhotoSaveRequest, edit: PhotoOriginalEdit,
                  onPlaceholder: @escaping @Sendable (String) -> Void) async throws -> SavedAsset {
        if let previous = try await journal.intent(request.operationID), previous.phase != .rejected && previous.phase != .prepared {
            do {
                guard previous.source == edit.source, previous.rawSHA256 == request.jpeg.sourceSHA256,
                      previous.jpegSHA256 == request.jpeg.outputSHA256 else { throw ResourceError.resourceChanged }
                switch try await findExport(operationID: request.operationID, sourceID: edit.source.id, knownAssetID: previous.pairedAssetID) {
                case .found(let asset): return asset
                case .needsReplacementCleanup(let asset): return try await completeReplacement(operationID: request.operationID, assetID: asset.assetID)
                default: throw PhotoLibraryWriteError.uncertain(.missingConfirmation)
                }
            } catch { throw PhotoLibraryWriteError.uncertain(.missingConfirmation) }
        }
        let prepared = try await prepare(request, edit: edit)
        let raw = prepared.raw
        var intent = prepared.intent
        defer { try? FileManager.default.removeItem(at: raw.fileURL) }
        try Task.checkCancellation()
        intent.phase = .submitted
        try await journal.store(intent)
        let assetID: String
        do {
            // The gateway waits for actual Photos completion, even if the caller is canceled.
            assetID = try await gateway.createPair(intent: intent, rawURL: raw.fileURL,
                jpegURL: request.jpeg.fileURL, onPlaceholder: onPlaceholder)
        } catch let error as PhotoLibraryWriteError {
            if case .rejected = error { intent.phase = .rejected; try await journal.store(intent); throw error }
            throw PhotoLibraryWriteError.uncertain(.missingConfirmation)
        } catch { throw PhotoLibraryWriteError.uncertain(.missingConfirmation) }
        do {
            intent.phase = .created; intent.pairedAssetID = assetID
            try await journal.store(intent)
            return try await finish(intent, assetID: assetID)
        } catch { throw PhotoLibraryWriteError.uncertain(.missingConfirmation) }
    }

    /// Every failure here is known to precede this operation's first Photos submission.
    private func prepare(_ request: PhotoSaveRequest, edit: PhotoOriginalEdit) async throws -> (intent: PhotoPairIntent, raw: LocalResource) {
        var retained: LocalResource?
        do {
            try Task.checkCancellation()
            try await requireAccess()
            guard edit.source.originalResources.jpeg == nil,
                  request.jpeg.sourceID == edit.source.id, request.jpeg.sourceRevision == edit.source.resourceRevision,
                  request.jpeg.settingsDigest == edit.recipe.settingsDigest,
                  try ResourceChecksum.sha256(request.jpeg.fileURL) == request.jpeg.outputSHA256,
                  try ImageGeometry.read(request.jpeg.fileURL) == ImageGeometry(encoded: .init(width: request.jpeg.width,
                      height: request.jpeg.height), orientation: request.jpeg.orientation) else {
                throw PhotoLibraryWriteError.invalidOutput("The paired export does not match this RAW and recipe.")
            }
            guard try await sourceReplacements()[edit.source.id] == nil else {
                throw PhotoLibraryWriteError.invalidOutput("This RAW already has a verified replacement. Export its paired photo instead.")
            }
            let current = try await reader.source(id: edit.source.id)
            guard sameOriginal(current, edit.source), let state = try await gateway.state(assetID: edit.source.id) else {
                throw PhotoLibraryWriteError.invalidOutput("The original RAW is no longer available.")
            }
            let raw = try await reader.materialize(edit.source.originalResources.raf, progress: { _ in })
            retained = raw
            guard raw.token == edit.source.originalResources.raf,
                  try ResourceChecksum.sha256(raw.fileURL) == request.jpeg.sourceSHA256,
                  try await gateway.state(assetID: edit.source.id) == state,
                  sameOriginal(try await reader.source(id: edit.source.id), edit.source) else {
                throw PhotoLibraryWriteError.invalidOutput("The original changed while preparing the pair.")
            }
            let intent = PhotoPairIntent(operationID: request.operationID, source: edit.source, originalState: state,
                rawSHA256: request.jpeg.sourceSHA256, jpegSHA256: request.jpeg.outputSHA256,
                width: request.jpeg.width, height: request.jpeg.height, orientation: request.jpeg.orientation)
            try await journal.store(intent)
            return (intent, raw)
        } catch {
            if let retained { try? FileManager.default.removeItem(at: retained.fileURL) }
            if error is CancellationError { throw error }
            switch error {
            case PhotoLibraryWriteError.authorization, PhotoLibraryWriteError.invalidOutput, PhotoLibraryWriteError.rejected: throw error
            case ResourceError.authorization(let access): throw PhotoLibraryWriteError.authorization(access)
            case ResourceError.insufficientStorage: throw PhotoLibraryWriteError.rejected(.insufficientStorage)
            default: throw PhotoLibraryWriteError.invalidOutput("Photos could not prepare the RAW+JPEG pair: \(error.localizedDescription)")
            }
        }
    }
    func findExport(operationID: UUID, sourceID: String, knownAssetID: String?) async throws -> SaveLookup {
        guard var intent = try await journal.intent(operationID), intent.source.id == sourceID else { return .notFound }
        let access = await gateway.access()
        guard access == .full || access == .limited else { return .inaccessible }
        let ids = try await gateway.matchingAssets(filename: intent.filename)
        guard ids.count <= 1 else { throw PhotoLibraryWriteError.ambiguousOperation(operationID) }
        guard let id = ids.first else { return access == .full ? .notFound : .inaccessible }
        guard (knownAssetID == nil || knownAssetID == id), (intent.pairedAssetID == nil || intent.pairedAssetID == id) else {
            throw PhotoLibraryWriteError.ambiguousOperation(operationID)
        }
        let verified = try await verify(intent, assetID: id)
        let observation = try await observeOriginal(sourceID)
        let originalState = observation.state
        if intent.phase != .removed, let originalState {
            guard originalState == intent.originalState.afterPairInsertion(),
                  verified.state.hasSameMetadata(as: intent.originalState) else { throw ResourceError.resourceChanged }
        }
        let confirmedRemoval = intent.phase == .removed || (originalState == nil && observation.absenceConfirmed)
        intent.verified = verified
        intent.pairedAssetID = id; intent.phase = confirmedRemoval ? .removed : .verified
        try await journal.store(intent)
        let asset = saved(intent, assetID: id)
        if confirmedRemoval { return .found(asset) }
        return originalState != nil ? .needsReplacementCleanup(asset) : .inaccessible
    }
    func completeReplacement(operationID: UUID, assetID: String) async throws -> SavedAsset {
        guard let intent = try await journal.intent(operationID), intent.pairedAssetID == assetID else {
            throw PhotoLibraryWriteError.uncertain(.missingConfirmation)
        }
        return try await finish(intent, assetID: assetID)
    }
    func hasIntent(_ operationID: UUID) async throws -> Bool { try await journal.intent(operationID) != nil }
    func sourceReplacements() async throws -> [SourceID: SourceID] {
        var result: [SourceID: SourceID] = [:]
        for intent in try await journal.all() {
            guard let verified = intent.verified, (intent.phase == .verified || intent.phase == .removed),
                  intent.pairedAssetID == verified.source.id else { continue }
            guard result[intent.source.id] == nil || result[intent.source.id] == verified.source.id else {
                throw PhotoLibraryWriteError.ambiguousOperation(intent.operationID)
            }
            result[intent.source.id] = verified.source.id
        }
        return result
    }

    private func finish(_ original: PhotoPairIntent, assetID: String) async throws -> SavedAsset {
        var intent = original
        let verified = try await verify(intent, assetID: assetID)
        if intent.phase == .removed { return saved(intent, assetID: assetID) }
        let observation = try await observeOriginal(intent.source.id)
        let originalState = observation.state
        if let originalState {
            guard originalState == intent.originalState.afterPairInsertion(), verified.state.hasSameMetadata(as: intent.originalState),
                  sameOriginal(try await reader.source(id: intent.source.id), intent.source) else { throw ResourceError.resourceChanged }
        } else if !observation.absenceConfirmed { throw PhotoLibraryWriteError.uncertain(.authorization) }
        intent.verified = verified; intent.phase = .verified; intent.pairedAssetID = assetID
        try await journal.store(intent) // A removal notification must already have a durable alias.
        try await requireAccess()
        try Task.checkCancellation()
        if originalState != nil {
            try await gateway.removeOriginal(intent: intent, verified: verified)
        }
        intent.phase = .removed
        try await journal.store(intent)
        return saved(intent, assetID: assetID)
    }
    private func verify(_ intent: PhotoPairIntent, assetID: String) async throws -> PhotoPairVerified {
        try Task.checkCancellation()
        try await requireAccess()
        guard assetID != intent.source.id, let state = try await gateway.state(assetID: assetID) else { throw ResourceError.resourceChanged }
        let source = try await reader.source(id: assetID)
        guard let jpeg = source.originalResources.jpeg, jpeg.assetID == assetID, jpeg.format == .jpeg,
              jpeg.role == .primaryOriginal, jpeg.originalFilename == intent.filename,
              source.originalResources.raf.role == .alternateOriginal,
              source.originalResources.raf.originalFilename == intent.source.originalResources.raf.originalFilename else {
            throw ResourceError.resourceChanged
        }
        let raw = try await reader.materialize(source.originalResources.raf, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: raw.fileURL) }
        guard raw.token == source.originalResources.raf, try ResourceChecksum.sha256(raw.fileURL) == intent.rawSHA256 else { throw ResourceError.resourceChanged }
        let rendered = try await reader.materialize(jpeg, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: rendered.fileURL) }
        guard rendered.token == jpeg, try ResourceChecksum.sha256(rendered.fileURL) == intent.jpegSHA256,
              try ImageGeometry.read(rendered.fileURL) == ImageGeometry(encoded: .init(width: intent.width, height: intent.height), orientation: intent.orientation),
              let image = CGImageSourceCreateWithURL(rendered.fileURL as CFURL, nil),
              CGImageSourceCreateImageAtIndex(image, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil,
              try await gateway.state(assetID: assetID) == state,
              sameOriginal(try await reader.source(id: assetID), source) else { throw ResourceError.resourceChanged }
        return PhotoPairVerified(source: source, state: state)
    }
    private func requireAccess() async throws {
        let access = await gateway.access()
        guard access == .full || access == .limited else { throw PhotoLibraryWriteError.authorization(access) }
    }
    private func observeOriginal(_ id: SourceID) async throws -> (state: PhotoPairAssetState?, absenceConfirmed: Bool) {
        let before = await gateway.access()
        guard before == .full || before == .limited else { throw PhotoLibraryWriteError.authorization(before) }
        let state = try await gateway.state(assetID: id)
        let after = await gateway.access()
        guard after == .full || after == .limited else { throw PhotoLibraryWriteError.authorization(after) }
        return (state, before == .full && after == .full)
    }
    private func sameOriginal(_ a: PhotoSource, _ b: PhotoSource) -> Bool {
        a.id == b.id && a.resourceRevision == b.resourceRevision && a.originalResources == b.originalResources
    }
    private func saved(_ intent: PhotoPairIntent, assetID: String) -> SavedAsset {
        SavedAsset(assetID: assetID, operationID: intent.operationID, photosGeometry: nil)
    }
}
