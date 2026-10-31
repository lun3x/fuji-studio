import FujiCameraCore
import Foundation

enum ExportCoordinatorError: Error, Sendable, Equatable {
    case alreadyActive, invalidSubmission, stopped
}
enum ExportPauseReason: Sendable, Equatable {
    case lifecycle, camera(ExportFailure), unresolvedSave, persistence(String)
}
struct ExportSummary: Sendable, Equatable {
    let completed: Int, failed: Int, skipped: Int, unprocessed: Int, unresolved: Int
    var replacementCleanup: Int = 0
    var processed: Int { completed + failed + skipped }
    var total: Int { processed + unprocessed + unresolved }
    var fractionCompleted: Double { total > 0 ? Double(processed) / Double(total) : 0 }
}
struct ExportEvent: Sendable, Equatable {
    let jobID: UUID
    let recipeLabel: String
    let stage: ExportJobState
    let currentItem: SourceID?
    let summary: ExportSummary
    let pauseReason: ExportPauseReason?
    var failures: [ExportFailure] = []
    /// The current run has stopped, including a pause; the frozen job remains resumable.
    let terminal: Bool
    let stopRequested: Bool
    var sequence: UInt64 = 0
    var activeProgress: ExportSummary? { !terminal && summary.total > 0 ? summary : nil }
}

/// Complete durable unfinished-job state at a coordinator sequence boundary. Transient events
/// at or before this watermark must not overwrite these canonical outcomes.
struct ExportRecoverySnapshot: Sendable {
    let sequence: UInt64
    let jobs: [ExportEvent]
}

/// One owned worker spans native operations. Caller cancellation never abandons Photos completion.
actor ExportCoordinator {
    private let reader: any PhotoLibraryReading
    private let camera: any CameraServing
    private let catalog: any CatalogStoring
    private let writer: any PhotoLibraryWriting
    private let pool: OriginalResourcePool
    private let cache: FileRenderCache
    private let scheduler: any CameraWorkScheduling
    private var sequence: UInt64 = 0
    private var occupied = false
    private var suspended = false
    private var admissionEpoch: UInt64 = 0
    private var recovering = false
    private var activeID: UUID?
    private var lastKnownJob: ExportJob?
    private var worker: Task<Void, Never>?
    private enum Stop { case cancel, pause }
    private var stop: Stop?
    private var observers: [UUID: AsyncStream<ExportEvent>.Continuation] = [:]

    init(reader: any PhotoLibraryReading, camera: any CameraServing, catalog: any CatalogStoring,
         writer: any PhotoLibraryWriting, pool: OriginalResourcePool, cache: FileRenderCache, scheduler: any CameraWorkScheduling) {
        self.reader = reader; self.camera = camera; self.catalog = catalog; self.writer = writer
        self.pool = pool; self.cache = cache; self.scheduler = scheduler
    }

    func events() -> AsyncStream<ExportEvent> {
        let id = UUID(), pair = AsyncStream<ExportEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        observers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return pair.stream
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    func sourceReplacements() async throws -> [SourceID: SourceID] { try await writer.sourceReplacements() }

    func start(sources: [PhotoSource], recipe: RecipeSnapshot, destination: ExportDestination = .separatePhoto) async throws -> UUID {
        guard !suspended else { throw ExportCoordinatorError.stopped }
        try reserve()
        let epoch = admissionEpoch
        do {
            guard destination != .createPair, !sources.isEmpty, Set(sources.map(\.id)).count == sources.count else { throw ExportCoordinatorError.invalidSubmission }
            try recipe.requireRenderable(using: RecipeCodecRegistry())
            try await validateCamera(recipe)
            for source in sources { try await validateSource(source); try checkStop(); guard epoch == admissionEpoch else { throw ExportCoordinatorError.stopped } }
            let job = ExportJob(id: UUID(), submittedAt: Date(), recipeSnapshot: recipe,
                items: sources.map { ExportItem(source: $0, operationID: UUID()) }, state: .queued, destination: destination)
            try await catalog.saveJob(job)
            launch(job, epoch: epoch)
            return job.id
        } catch { occupied = false; throw error }
    }

    func cancel(jobID: UUID) async {
        if activeID == jobID {
            stop = .cancel
            let running = worker
            if let job = try? await catalog.job(id: jobID) { emit(job) }
            await running?.value
            return
        }
        guard !occupied else { return }
        occupied = true
        defer { occupied = false }
        do {
            try await reconcile(jobID)
            try await cancelRemaining(jobID)
            emit(try await catalog.job(id: jobID), terminal: true)
        } catch {
            if let job = try? await catalog.job(id: jobID) {
                emit(job, reason: .persistence(String(describing: error)), terminal: true)
            }
        }
    }
    func pause(jobID: UUID) async {
        guard activeID == jobID else { return }
        if stop == nil { stop = .pause }
        let running = worker
        if let job = try? await catalog.job(id: jobID) { emit(job, reason: .lifecycle) }
        await running?.value
    }
    /// Revokes admission even while start/reopen awaits validation or persistence. It never
    /// cancels a submitted Photos transaction. The current worker classifies its actual result.
    func suspend() async {
        admissionEpoch &+= 1
        suspended = true
        if activeID != nil { stop = .pause }
        let running = worker
        if let job = lastKnownJob { emit(job, reason: .lifecycle) }
        await running?.value
    }
    func allowForegroundWork() { suspended = false }
    func pauseActiveWork() async {
        admissionEpoch &+= 1
        guard occupied else { return }
        stop = .pause
        let running = worker
        if let job = lastKnownJob { emit(job, reason: .lifecycle) }
        await running?.value
    }

    func resume(jobID: UUID) async throws { try await reopen(jobID, retryFailures: false) }
    func retry(jobID: UUID) async throws { try await reopen(jobID, retryFailures: true) }

    /// Owns only verification/removal of existing pairs, without admitting camera work.
    func finishReplacements(jobID: UUID) async throws {
        guard !suspended else { throw ExportCoordinatorError.stopped }
        try reserve()
        let epoch = admissionEpoch
        do {
            let job = try await catalog.job(id: jobID)
            guard !suspended, stop == nil, epoch == admissionEpoch else { throw ExportCoordinatorError.stopped }
            activeID = job.id; lastKnownJob = job
            worker = Task { await self.runReplacementCleanup(job.id) }
        } catch { occupied = false; throw error }
    }

    private func runReplacementCleanup(_ id: UUID) async {
        var reason: ExportPauseReason?
        do {
            try checkStop()
            var job = try await catalog.job(id: id)
            job.state = .pendingSave
            try await catalog.saveJob(job); emit(job)
            try await reconcile(id, finishReplacements: true)
        } catch {
            reason = error as? ExportCoordinatorError == .stopped ? .lifecycle : .persistence(String(describing: error))
        }
        // Cancellation can stop reconciliation before cleanup is submitted. Classify the
        // remaining items even on that path, while retaining every uncertain Photos intent.
        do {
            if stop == .cancel { try await cancelRemaining(id) }
            var job = try await catalog.job(id: id)
            if stop != nil || suspended { reason = .lifecycle }
            else if Self.hasUnresolved(job), reason == nil { reason = .unresolvedSave }
            job.state = Self.hasUnresolved(job) ? .unresolved : Self.allSaved(job) ? .saved : stop == .cancel ? .cancelled : .paused
            try await catalog.saveJob(job)
        } catch {
            reason = .persistence(String(describing: error))
        }
        let final = (try? await catalog.job(id: id)) ?? lastKnownJob
        occupied = false; activeID = nil; worker = nil; stop = nil; lastKnownJob = nil
        if let final { emit(final, reason: reason, terminal: true) }
    }

    private func reserve() throws {
        guard !occupied else { throw ExportCoordinatorError.alreadyActive }
        occupied = true; stop = nil
    }
    private func launch(_ job: ExportJob, epoch: UInt64) {
        if suspended || stop != nil || epoch != admissionEpoch {
            occupied = false
            emit(job, reason: .lifecycle, terminal: true)
            stop = nil
            return
        }
        activeID = job.id; lastKnownJob = job; stop = nil
        worker = Task { await self.run(job.id) }
    }
    private func reopen(_ id: UUID, retryFailures: Bool) async throws {
        guard !suspended else { throw ExportCoordinatorError.stopped }
        try reserve()
        let epoch = admissionEpoch
        do {
            try await reconcile(id)
            var job = try await catalog.job(id: id)
            var released: [RenderKey] = []
            for index in job.items.indices {
                switch job.items[index].state {
                case .preparing, .converting, .unprocessed: job.items[index].state = .queued
                case .failed, .cancelled:
                    if retryFailures { job.items[index].state = .queued }
                case .pendingSave(let pending):
                    if pending.submission == .notSubmitted,
                       pending.jpeg.cameraContext.supportVersion != (try RecipeCodecRegistry().supportVersion(for: job.recipeSnapshot.cameraContext)) {
                        job.items[index].state = .queued
                        released.append(pending.jpeg.key)
                    }
                default: break
                }
            }
            try await catalog.saveJob(job)
            for key in released { try await releaseIfUnreferenced(key) }
            launch(job, epoch: epoch)
        } catch { occupied = false; throw error }
    }

    /// Rechecks exact operation identity only. Call on library changes or explicit foreground recovery.
    /// This method never starts a PhotoKit transaction or camera conversion.
    @discardableResult func recover() async throws -> ExportRecoverySnapshot {
        try reserve(); recovering = true
        defer { occupied = false; recovering = false }
        var reconciled: [ExportJob] = []
        for job in try await catalog.unfinishedJobs() {
            try await reconcile(job.id, releaseFiles: false)
            let current = try await catalog.job(id: job.id)
            reconciled.append(current)
            emit(current, terminal: true)
        }
        // Single coordinator admission is still held. Obtain the complete reference set before
        // deleting anything; a failed catalog enumeration releases no reservations.
        let unfinished = try await catalog.unfinishedJobs()
        let references = Set(unfinished.flatMap { job in
            job.items.compactMap { Self.pending($0.state)?.jpeg.key }
        })
        for key in await cache.pinnedKeys() where !references.contains(key) { await cache.unpin(key) }
        sequence &+= 1
        return ExportRecoverySnapshot(sequence: sequence, jobs: reconciled.map { progress($0, terminal: true) })

    }

    private func run(_ id: UUID) async {
        var reason: ExportPauseReason?
        do {
            try await scheduler.beginExport(jobID: id)
            var job = try await catalog.job(id: id)
            for index in job.items.indices {
                if stop != nil || suspended { break }
                job = try await catalog.job(id: id)
                do { try await process(job, index) }
                catch {
                    if error is CatalogError { throw error }
                    if error as? ExportCoordinatorError == .stopped { break }
                    let pending = Self.pending(try await catalog.job(id: id).items[index].state)
                    // Only durable proof of no submission permits an ordinary per-source failure.
                    if let pending, pending.submission != .notSubmitted { throw error }
                    let failure = Self.failure(error)
                    if Self.isSessionFailure(error) {
                        if pending == nil { try await setState(id, index, .queued, stage: .paused) }
                        reason = .camera(failure); break
                    }
                    try await setState(id, index, .failed(failure), stage: .failed)
                    if let pending { try await releaseIfUnreferenced(pending.jpeg.key) }
                }
                let latest = try await catalog.job(id: id)
                if case .unresolved(let pending) = latest.items[index].state, pending.replacementCleanupAssetID == nil,
                   latest.items[index].state != job.items[index].state {
                    reason = .unresolvedSave; break
                }
                if reason != nil || stop != nil { break }
            }
            if reason == nil, stop == nil, !suspended {
                try await reconcile(id, finishReplacements: true, allowingPreviousEdits: false)
            }
            var final = try await catalog.job(id: id)
            if stop == .cancel {
                try await cancelRemaining(id)
            } else {
                if stop == .pause || suspended { reason = .lifecycle }
                if Self.hasUnresolved(final), reason == nil { reason = .unresolvedSave }
                final.state = Self.hasUnresolved(final) ? .unresolved : Self.allSaved(final) ? .saved : reason != nil ? .paused : Self.finalState(final)
                try await catalog.saveJob(final)
            }
        } catch {
            reason = .persistence(String(describing: error))
            // Keep the durable attempt even when updating progress also fails.
            if var job = try? await catalog.job(id: id) {
                job.state = Self.hasUnresolved(job) ? .unresolved : Self.allSaved(job) ? .saved : .paused
                try? await catalog.saveJob(job)
            }
        }
        await scheduler.endExport(jobID: id)
        let final = (try? await catalog.job(id: id)) ?? lastKnownJob
        occupied = false; activeID = nil; worker = nil; stop = nil; lastKnownJob = nil
        if let final { emit(final, reason: reason, terminal: true) }
    }

    private func process(_ job: ExportJob, _ index: Int) async throws {
        let id = job.id, item = job.items[index]
        switch item.state {
        case .queued, .preparing, .converting:
            let source = item.source, recipe = job.recipeSnapshot
            let jpeg = try await scheduler.withExportItem(jobID: id) {
                try await self.admit(source)
                try await self.setState(id, index, .preparing, stage: .preparing)
                return try await self.pool.withPreparedRAW(source: source, beforeMaterialize: { try await self.admit(source) }) { raw in
                    try await self.render(raw, recipe: recipe, jobID: id, index: index)
                }
            }
            try checkStop()
            let pinned = try await cache.pin(jpeg.key)
            let pending = PendingSave(operationID: item.operationID, jpeg: jpeg.relocated(to: pinned))
            try await setState(id, index, .pendingSave(pending), stage: .pendingSave)
            try checkStop()
            try await submit(id, index)
        case .pendingSave(let pending):
            if case .notSubmitted = pending.submission {
                try await admit(item.source)
                try await submit(id, index)
            }
        default: break
        }
    }

    private func cancelRemaining(_ id: UUID) async throws {
        var job = try await catalog.job(id: id)
        var released: [RenderKey] = []
        for index in job.items.indices {
            switch job.items[index].state {
            case .queued, .preparing, .converting, .unprocessed: job.items[index].state = .cancelled
            case .pendingSave(let pending):
                if case .notSubmitted = pending.submission {
                    job.items[index].state = .cancelled; released.append(pending.jpeg.key)
                }
            default: break
            }
        }
        job.state = Self.hasUnresolved(job) ? .unresolved : Self.allSaved(job) ? .saved : .cancelled
        try await catalog.saveJob(job)
        for key in released { try await releaseIfUnreferenced(key) }
    }

    private func render(_ raw: PreparedRAW, recipe: RecipeSnapshot, jobID: UUID, index: Int) async throws -> CameraJPEG {
        try checkStop()
        let context = try await validateCamera(recipe)
        guard raw.metadata.cameraModel == context.model else { throw ResourceError.incompatibleCamera(raw.metadata.cameraModel) }
        let key = RenderKey(sourceID: raw.sourceID, sourceRevision: raw.sourceRevision, sourceSHA256: raw.sha256,
            settingsDigest: recipe.settingsDigest, cameraContext: context, width: raw.metadata.recordedGeometry.width,
            height: raw.metadata.recordedGeometry.height, orientation: raw.metadata.orientation,
            policy: .fullSizeFineRecordedGeometry, quality: .fullResolutionFine)
        if let hit = await cache.lookup(key) {
            guard try await camera.executionContext() == context else { throw CameraServiceError.unsupportedContext }
            return hit
        }
        try checkStop()
        try await setState(jobID, index, .converting, stage: .converting)
        try checkStop()
        let jpeg = try await camera.render(raw: raw, recipe: recipe, policy: .fullSizeFineRecordedGeometry)
        guard jpeg.key == key else {
            try? FileManager.default.removeItem(at: jpeg.fileURL)
            throw CameraServiceError.invalidOutput
        }
        do { try await cache.store(jpeg, key: key) }
        catch { try? FileManager.default.removeItem(at: jpeg.fileURL); throw error }
        guard let retained = await cache.lookup(key) else { throw RenderCacheError.missing }
        return retained
    }

    private func submit(_ id: UUID, _ index: Int) async throws {
        var job = try await catalog.job(id: id)
        guard var pending = Self.pending(job.items[index].state), case .notSubmitted = pending.submission else { return }
        try checkStop()
        guard await cache.lookup(pending.jpeg.key) == pending.jpeg else { throw RenderCacheError.pinConflict }
        pending.submission = .submitted(at: Date())
        try await setState(id, index, .pendingSave(pending), stage: .pendingSave)
        if suspended || stop != nil {
            // We own the only writer invocation and have not called it. Persist that proof
            // before making this intent resumable; a crash between writes remains a rejection.
            pending.submission = .definitivelyRejected(at: pending.submission.attemptedAt!, reason: "Stopped before invoking Photos")
            try await setState(id, index, .pendingSave(pending), stage: .paused)
            pending.submission = .notSubmitted
            try await setState(id, index, .pendingSave(pending), stage: .paused)
            throw ExportCoordinatorError.stopped
        }
        let stream = AsyncStream<String>.makeStream()
        let placeholders = Task {
            for await assetID in stream.stream { try await self.recordPlaceholder(id, index, assetID) }
        }
        let source = job.items[index].source
        let createsPair = job.destination == .updateOriginal && source.originalResources.jpeg == nil
        let result: Result<SavedAsset, Error>
        do {
            result = .success(try await writer.saveJPEG(.init(jpeg: pending.jpeg, operationID: pending.operationID,
                captureDate: source.captureDate, location: source.location,
                originalEdit: job.destination == .updateOriginal ? PhotoOriginalEdit(source: source, recipe: job.recipeSnapshot) : nil,
                deferPairRemoval: createsPair, pairBatchID: createsPair ? job.id : nil),
                onPlaceholder: { stream.continuation.yield($0) }))
        } catch { result = .failure(error) }
        stream.continuation.finish()
        // No completion/confirmation can race a late placeholder journal write.
        let placeholderResult = await placeholders.result
        job = try await catalog.job(id: id)
        pending = Self.pending(job.items[index].state) ?? pending
        switch result {
        case .success(let asset):
            if createsPair {
                guard asset.operationID == pending.operationID, pending.placeholderID == asset.assetID else {
                    throw CatalogError.conflictingOperation(pending.operationID)
                }
                pending.replacementCleanupAssetID = asset.assetID
                try await setState(id, index, .pendingSave(pending), stage: .pendingSave)
            } else { try await confirm(job, index, pending, asset) }
        case .failure(let error):
            if Self.definitiveRejection(error) {
                pending.submission = .definitivelyRejected(at: pending.submission.attemptedAt!, reason: String(describing: error))
                try await setState(id, index, .pendingSave(pending), stage: .pendingSave)
                try await setState(id, index, .failed(Self.failure(error)), stage: .failed)
                try await releaseIfUnreferenced(pending.jpeg.key)
            } else {
                pending.submission = .unknown(at: pending.submission.attemptedAt!)
                try await setState(id, index, .unresolved(pending), stage: .unresolved)
            }
        }
        // Native completion was classified first, even if placeholder persistence failed.
        try placeholderResult.get()
    }

    private func recordPlaceholder(_ id: UUID, _ index: Int, _ assetID: String) async throws {
        let job = try await catalog.job(id: id)
        guard var pending = Self.pending(job.items[index].state), !assetID.isEmpty,
              pending.placeholderID == nil || pending.placeholderID == assetID else {
            throw CatalogError.invalidState("Conflicting Photos placeholder")
        }
        pending.placeholderID = assetID
        try await setState(id, index, .pendingSave(pending), stage: .pendingSave)
    }

    private func reconcile(_ id: UUID, releaseFiles: Bool = true, finishReplacements: Bool = false,
                           allowingPreviousEdits: Bool = true) async throws {
        let original = try await catalog.job(id: id)
        var replacements: [(index: Int, pending: PendingSave, asset: SavedAsset)] = []
        for index in original.items.indices {
            let job = try await catalog.job(id: id)
            guard var pending = Self.pending(job.items[index].state) else { continue }
            switch pending.submission {
            case .notSubmitted: continue
            case .definitivelyRejected(_, let reason):
                try await setState(id, index, .failed(.unresolvedSave(reason)), stage: .failed)
                if releaseFiles { try await releaseIfUnreferenced(pending.jpeg.key) }
            case .submitted, .unknown:
                let lookup = try? await writer.findExport(operationID: pending.operationID, knownAssetID: pending.placeholderID,
                    originalAssetID: job.destination == .updateOriginal ? job.items[index].source.id : nil)
                if case .found(let asset) = lookup {
                    try await confirm(job, index, pending, asset, releaseFile: releaseFiles)
                } else {
                    if case .needsReplacementCleanup(let candidate) = lookup {
                        pending.replacementCleanupAssetID = candidate.assetID
                        replacements.append((index, pending, candidate))
                    } else { pending.replacementCleanupAssetID = nil }
                    pending.submission = .unknown(at: pending.submission.attemptedAt!)
                    try await setState(id, index, .unresolved(pending), stage: .unresolved)
                }
            }
        }
        if finishReplacements, !replacements.isEmpty {
            try checkStop()
            guard let saved = try? await writer.completeReplacements(replacements.map(\.asset), allowingPreviousEdits: allowingPreviousEdits,
                beforeRemoval: { try await self.checkStop() }) else { return }
            guard saved.count == replacements.count,
                  Set(saved.map(\.operationID)).count == saved.count,
                  replacements.allSatisfy({ candidate in saved.contains { $0.operationID == candidate.asset.operationID && $0.assetID == candidate.asset.assetID } }) else {
                throw CatalogError.invalidState("Conflicting batch replacement confirmation")
            }
            for candidate in replacements {
                let job = try await catalog.job(id: id)
                let pending = Self.pending(job.items[candidate.index].state) ?? candidate.pending
                try await confirm(job, candidate.index, pending, candidate.asset, releaseFile: releaseFiles)
            }
        }
    }

    private func confirm(_ job: ExportJob, _ index: Int, _ pending: PendingSave, _ asset: SavedAsset, releaseFile: Bool = true) async throws {
        guard asset.operationID == pending.operationID, !asset.assetID.isEmpty,
              pending.placeholderID == nil || pending.placeholderID == asset.assetID,
              let at = pending.submission.attemptedAt else { throw CatalogError.conflictingOperation(pending.operationID) }
        let version = SavedVersion(id: UUID(), sourceID: job.items[index].source.id, outputAssetID: asset.assetID,
            recipeSnapshot: job.recipeSnapshot, operationID: pending.operationID, exportedAt: at, jpeg: pending.jpeg,
            availability: .available, destination: job.destination.forSource(job.items[index].source))
        try await catalog.confirmSaved(jobID: job.id, operationID: pending.operationID, version: version)
        if releaseFile { try await releaseIfUnreferenced(pending.jpeg.key) }
    }

    private func releaseIfUnreferenced(_ key: RenderKey) async throws {
        // Pins are reservations, not reference counts. Another deliberate job may share the pixels.
        let jobs = try await catalog.unfinishedJobs()
        guard !jobs.contains(where: { $0.items.contains { Self.pending($0.state)?.jpeg.key == key } }) else { return }
        await cache.unpin(key)
    }
    private func setState(_ id: UUID, _ index: Int, _ state: ExportItemState, stage: ExportJobState) async throws {
        var job = try await catalog.job(id: id)
        job.items[index].state = state; job.state = stage
        try await catalog.saveJob(job); emit(job, current: job.items[index].source.id)
    }
    private func checkStop() throws { if stop != nil || suspended { throw ExportCoordinatorError.stopped } }
    private func admit(_ source: PhotoSource) async throws { try checkStop(); try await validateSource(source); try checkStop() }
    private func validateSource(_ source: PhotoSource) async throws {
        let token = source.originalResources.raf
        guard token.assetID == source.id, token.sourceRevision == source.resourceRevision,
              token.role != .adjusted, token.format == .raf else { throw ResourceError.resourceChanged }
        let current = try await reader.source(id: source.id)
        guard current.id == source.id, current.resourceRevision == source.resourceRevision,
              current.originalResources == source.originalResources else { throw ResourceError.resourceChanged }
        if case .incompatible(let model) = await pool.compatibility(for: source) { throw ResourceError.incompatibleCamera(model) }
    }
    @discardableResult private func validateCamera(_ recipe: RecipeSnapshot) async throws -> CameraExecutionContext {
        try recipe.requireRenderable(using: RecipeCodecRegistry())
        let settings = try recipe.settings(using: RecipeCodecRegistry()), current = try await camera.executionContext()
        guard recipe.cameraContext.model == current.model, recipe.cameraContext.firmware == current.firmware,
              recipe.cameraContext.capability == current.capability, (try RecipeCodecRegistry().supportVersion(for: recipe.cameraContext)) == current.supportVersion else {
            throw CameraServiceError.unsupportedContext
        }
        return current
    }
    private static func pending(_ state: ExportItemState) -> PendingSave? {
        switch state { case .pendingSave(let p), .unresolved(let p): p; default: nil }
    }
    private static func hasUnresolved(_ job: ExportJob) -> Bool {
        job.items.contains { item in
            guard let p = pending(item.state) else { return false }
            return switch p.submission { case .submitted, .unknown: true; default: false }
        }
    }
    private static func allSaved(_ job: ExportJob) -> Bool {
        job.items.allSatisfy { if case .saved = $0.state { true } else { false } }
    }
    private static func finalState(_ job: ExportJob) -> ExportJobState {
        if Self.allSaved(job) { return .saved }
        if job.items.contains(where: { if case .failed = $0.state { true } else { false } }) { return .failed }
        return .unprocessed
    }
    private static func definitiveRejection(_ error: Error) -> Bool {
        switch error {
        case PhotoLibraryWriteError.authorization, PhotoLibraryWriteError.invalidOutput, PhotoLibraryWriteError.rejected: true
        // PhotoLibraryWriter only throws cancellation at its documented pre-submission check.
        case is CancellationError: true
        default: false
        }
    }
    private static func isSessionFailure(_ error: Error) -> Bool {
        guard let error = error as? CameraServiceError else { return false }
        return switch error {
        case .unsupportedSource, .unsupportedSettings, .sourceChanged, .invalidOutput, .storage: false
        default: true
        }
    }
    private static func failure(_ error: Error) -> ExportFailure {
        switch error {
        case ResourceError.authorization, PhotoLibraryWriteError.authorization, PhotoLibraryWriteError.rejected(.authorization): .authorization
        case ResourceError.inaccessibleAsset: .inaccessible
        case ResourceError.insufficientStorage, CameraServiceError.storage, RenderCacheError.storage, PhotoLibraryWriteError.rejected(.insufficientStorage): .insufficientStorage
        case CameraServiceError.unsupportedSource: .unsupportedSource
        case CameraServiceError.unsupportedSettings, CameraServiceError.unsupportedProfile: .unsupportedSettings(String(describing: error))
        case let error as CameraServiceError where isSessionFailure(error): .transport(String(describing: error))
        default: .preparation(String(describing: error))
        }
    }
    private func emit(_ job: ExportJob, current: SourceID? = nil, reason: ExportPauseReason? = nil, terminal: Bool = false) {
        if activeID == job.id { lastKnownJob = job }
        sequence &+= 1
        let event = progress(job, current: current, reason: reason, terminal: terminal)
        observers.values.forEach { $0.yield(event) }
    }
    private func progress(_ job: ExportJob, current: SourceID? = nil, reason: ExportPauseReason? = nil, terminal: Bool) -> ExportEvent {
        var completed = 0, failed = 0, skipped = 0, unprocessed = 0, unresolved = 0, replacementCleanup = 0
        for item in job.items {
            if Self.pending(item.state)?.replacementCleanupAssetID != nil { replacementCleanup += 1 }
            switch item.state {
            case .saved: completed += 1
            case .failed: failed += 1
            case .cancelled: skipped += 1
            case .unresolved: unresolved += 1
            case .pendingSave(let p):
                if case .notSubmitted = p.submission { unprocessed += 1 } else { unresolved += 1 }
            default: unprocessed += 1
            }
        }
        let failures = job.items.compactMap { item -> ExportFailure? in
            if case .failed(let failure) = item.state { return failure }; return nil
        }.reduce(into: [ExportFailure]()) { if !$0.contains($1) { $0.append($1) } }
        return ExportEvent(jobID: job.id, recipeLabel: job.recipeSnapshot.name, stage: job.state, currentItem: current,
            summary: .init(completed: completed, failed: failed, skipped: skipped, unprocessed: unprocessed, unresolved: unresolved, replacementCleanup: replacementCleanup),
            pauseReason: reason, failures: failures, terminal: terminal || recovering, stopRequested: stop != nil, sequence: sequence)
    }
}
