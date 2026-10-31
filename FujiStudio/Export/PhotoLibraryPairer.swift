import Foundation
import FujiCameraCore
import ImageIO

protocol PhotoPairGateway: Sendable {
    func access() async -> LibraryAccess
    func state(assetID: String) async throws -> PhotoPairAssetState?
    func createPair(intent: PhotoPairIntent, rawURL: URL, jpegURL: URL,
                    onPlaceholder: @escaping @Sendable (String) -> Void) async throws -> String
    func matchingAssets(filename: String) async throws -> [String]
    func removeOriginals(_ removals: [PhotoPairRemoval]) async throws
}

struct PhotoPairRemoval: Sendable {
    let intent: PhotoPairIntent
    let verified: PhotoPairVerified
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
                case .needsReplacementCleanup(let asset):
                    return request.deferPairRemoval ? asset : try await completeReplacement(operationID: request.operationID, assetID: asset.assetID)
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
            if request.deferPairRemoval {
                guard case .needsReplacementCleanup(let asset) = try await findExport(operationID: intent.operationID,
                    sourceID: intent.source.id, knownAssetID: assetID) else { throw ResourceError.resourceChanged }
                return asset
            }
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
            var intent = PhotoPairIntent(operationID: request.operationID, source: edit.source, originalState: state,
                rawSHA256: request.jpeg.sourceSHA256, jpegSHA256: request.jpeg.outputSHA256,
                width: request.jpeg.width, height: request.jpeg.height, orientation: request.jpeg.orientation)
            if let batchID = request.pairBatchID {
                intent.batchID = batchID
                intent.batchSequence = try await nextSequence(batchID)
            }
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
            let expected = try await expectedStates(intent)
            guard originalState.assetID == intent.source.id,
                  originalState.hasSameMetadata(as: expected.original),
                  verified.state.hasSameMetadata(as: expected.pair),
                  sameOriginal(try await reader.source(id: sourceID), intent.source) else { throw ResourceError.resourceChanged }
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
        return try await finish(intent, assetID: assetID, explicitRemoval: true)
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

    private func finish(_ original: PhotoPairIntent, assetID: String, explicitRemoval: Bool = false) async throws -> SavedAsset {
        let asset = saved(original, assetID: assetID)
        _ = try await completeReplacements([asset], allowingPreviousEdits: explicitRemoval)
        return asset
    }

    func completeReplacements(_ assets: [SavedAsset], allowingPreviousEdits: Bool,
                              beforeRemoval: @escaping @Sendable () async throws -> Void = {}) async throws -> [SavedAsset] {
        guard Set(assets.map(\.operationID)).count == assets.count,
              Set(assets.map(\.assetID)).count == assets.count else { throw ResourceError.resourceChanged }
        var ready: [PhotoPairRemoval] = []
        for asset in assets {
            guard let intent = try await journal.intent(asset.operationID), intent.pairedAssetID == asset.assetID else {
                throw PhotoLibraryWriteError.uncertain(.missingConfirmation)
            }
            ready.append(try await prepareRemoval(intent, assetID: asset.assetID, explicitRemoval: allowingPreviousEdits))
        }
        // Persist one event for each batch's atomic removal before submission, so recovery
        // can replay its album shifts even if the completion receipt write is interrupted.
        for batchID in Set(ready.filter { $0.intent.phase != .removed }.compactMap { $0.intent.batchID }) {
            let sequence = try await nextSequence(batchID)
            for index in ready.indices where ready[index].intent.batchID == batchID && ready[index].intent.phase != .removed {
                var intent = ready[index].intent; intent.removalBatchSequence = sequence
                try await journal.store(intent)
                ready[index] = PhotoPairRemoval(intent: intent, verified: ready[index].verified)
            }
        }
        try await requireAccess(); try Task.checkCancellation()
        let removals = ready.filter { $0.intent.phase != .removed && $0.intent.removalOriginalState != nil }
        if !removals.isEmpty {
            // The owned export worker revokes admission during the lengthy read-back above.
            // Once admitted here, it drains the real PhotoKit completion independently.
            try await beforeRemoval()
            try await gateway.removeOriginals(removals)
        }
        for removal in ready {
            var intent = removal.intent; intent.phase = .removed
            try await journal.store(intent)
        }
        return assets
    }

    private func prepareRemoval(_ original: PhotoPairIntent, assetID: String, explicitRemoval: Bool) async throws -> PhotoPairRemoval {
        var intent = original
        if intent.phase == .removed {
            return PhotoPairRemoval(intent: intent, verified: try await verify(intent, assetID: assetID))
        }
        let observation = try await observeOriginal(intent.source.id)
        let originalState = observation.state
        if originalState == nil && !observation.absenceConfirmed { throw PhotoLibraryWriteError.uncertain(.authorization) }
        let verified = try await verify(intent, assetID: assetID)
        if let originalState {
            let expected = try await expectedStates(intent)
            guard originalState.assetID == intent.source.id,
                  (explicitRemoval ? originalState.hasSameMetadata(as: expected.original) : originalState == expected.original),
                  verified.state.hasSameMetadata(as: expected.pair),
                  sameOriginal(try await reader.source(id: intent.source.id), intent.source) else { throw ResourceError.resourceChanged }
            let raw = try await reader.materialize(intent.source.originalResources.raf, progress: { _ in })
            defer { try? FileManager.default.removeItem(at: raw.fileURL) }
            guard raw.token == intent.source.originalResources.raf,
                  try ResourceChecksum.sha256(raw.fileURL) == intent.rawSHA256 else { throw ResourceError.checksumMismatch }
        }
        let finalObservation = try await observeOriginal(intent.source.id)
        guard finalObservation.state == originalState,
              originalState != nil || finalObservation.absenceConfirmed else { throw ResourceError.resourceChanged }
        intent.verified = verified; intent.phase = originalState == nil ? .removed : .verified; intent.pairedAssetID = assetID
        if originalState != nil || intent.removalBatchSequence == nil { intent.removalOriginalState = originalState }
        try await journal.store(intent) // A removal notification must already have a durable alias.
        return PhotoPairRemoval(intent: intent, verified: verified)
    }

    private func nextSequence(_ batchID: UUID) async throws -> Int {
        (try await journal.all().filter { $0.batchID == batchID }
            .flatMap { [$0.batchSequence, $0.removalBatchSequence].compactMap { $0 } }.max() ?? -1) + 1
    }

    /// Replay this job's own insertions and confirmed atomic removals. External album
    /// changes still fail the snapshot guards, while split cleanup/retry remains usable.
    private func expectedStates(_ intent: PhotoPairIntent) async throws -> (original: PhotoPairAssetState, pair: PhotoPairAssetState) {
        var original = intent.originalState.afterPairInsertion(), pair = intent.originalState
        if let batchID = intent.batchID, let sequence = intent.batchSequence {
            let intents = try await journal.all().filter { $0.batchID == batchID }
            let insertions = intents.filter { ($0.batchSequence ?? -1) > sequence && $0.pairedAssetID != nil }
            let removals = intents.filter { $0.phase == .removed && ($0.removalBatchSequence ?? -1) > sequence }
            let events = Set(insertions.compactMap(\.batchSequence) + removals.compactMap(\.removalBatchSequence))
            for event in events.sorted() {
                for next in insertions where next.batchSequence == event {
                    for (album, insertion) in next.originalState.albumPositions {
                        if let p = original.albumPositions[album], insertion <= p { original.albumPositions[album] = p + 1 }
                        if let p = pair.albumPositions[album], insertion <= p { pair.albumPositions[album] = p + 1 }
                    }
                }
                let removed = removals.filter { $0.removalBatchSequence == event }
                for (album, position) in original.albumPositions {
                    original.albumPositions[album] = position - removed.filter { ($0.removalOriginalState?.albumPositions[album] ?? Int.max) < position }.count
                }
                for (album, position) in pair.albumPositions {
                    pair.albumPositions[album] = position - removed.filter { ($0.removalOriginalState?.albumPositions[album] ?? Int.max) < position }.count
                }
            }
        }
        return (original, pair)
    }
    private func verify(_ intent: PhotoPairIntent, assetID: String) async throws -> PhotoPairVerified {
        try Task.checkCancellation()
        try await requireAccess()
        guard assetID != intent.source.id, let state = try await gateway.state(assetID: assetID) else { throw ResourceError.resourceChanged }
        let source = try await reader.source(id: assetID)
        // Photos normalizes the RAF filename to the JPEG stem; its role and exact bytes
        // identify the copied original, independently of that new filename.
        guard let jpeg = source.originalResources.jpeg, jpeg.assetID == assetID, jpeg.format == .jpeg,
              jpeg.role == .primaryOriginal, jpeg.originalFilename == intent.filename,
              source.originalResources.raf.role == .alternateOriginal else {
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
