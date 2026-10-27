import Foundation

enum PreviewState: Sendable, Equatable {
    case loading, progress(Double), ready(URL), failed(PreviewFailure)
}
enum PreviewFailure: Sendable, Equatable {
    case rawDisplayUnavailable, source(ResourceError), camera(CameraServiceError), cache(RenderCacheError), cancelled, unavailable
}
struct PreviewEvent: Sendable, Equatable {
    /// Local display-intent token. Never substitute this for WorkspacePreviewRequest.generation.
    let generation: UInt64
    let sourceID: SourceID
    let version: VersionID?
    let workspaceRequest: WorkspacePreviewRequest?
    let state: PreviewState
    var displayFile: DisplayFileLease? = nil
    var jpeg: CameraJPEG? = nil
    var displayIntent: UInt64? = nil
}

actor PreviewCoordinator {
    /// Resolves existing paired JPEG/saved versions; RAW is always handled through the shared pool.
    typealias StoredDisplay = @Sendable (PhotoSource, VersionID, @escaping @Sendable (Double) -> Void) async throws -> DisplayFileLease
    private let pool: OriginalResourcePool
    private let camera: any CameraServing
    private let scheduler: any CameraWorkScheduling
    private let cache: FileRenderCache
    private let rawRenderer: RawDisplayRenderer
    private let storedDisplay: StoredDisplay
    private var currentDisplayFile: DisplayFileLease?
    private var currentJPEG: CameraJPEG?
    private var displayIntent: UInt64?
    private var generation: UInt64 = 0
    private var loadingGeneration: UInt64?
    private var source: PhotoSource?
    private var observers: [UUID: AsyncStream<PreviewEvent>.Continuation] = [:]
    private(set) var displayedVersion: VersionID?

    init(pool: OriginalResourcePool, camera: any CameraServing, scheduler: any CameraWorkScheduling,
         cache: FileRenderCache, rawRenderer: RawDisplayRenderer, storedDisplay: @escaping StoredDisplay) {
        self.pool = pool; self.camera = camera; self.scheduler = scheduler; self.cache = cache
        self.rawRenderer = rawRenderer; self.storedDisplay = storedDisplay
    }

    func events() -> AsyncStream<PreviewEvent> {
        let id = UUID(), pair = AsyncStream<PreviewEvent>.makeStream(bufferingPolicy: .bufferingNewest(2))
        observers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return pair.stream
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    private func emit(_ state: PreviewState, source: PhotoSource, generation: UInt64, version: VersionID?, request: WorkspacePreviewRequest?) {
        switch state {
        case .ready, .failed: if loadingGeneration == generation { loadingGeneration = nil }
        default: break
        }
        let file: DisplayFileLease? = if case .ready = state { currentDisplayFile } else { nil }
        let event = PreviewEvent(generation: generation, sourceID: source.id, version: version,
            workspaceRequest: request, state: state, displayFile: file, jpeg: file == nil ? nil : currentJPEG, displayIntent: displayIntent)
        observers.values.forEach { $0.yield(event) }
    }
    private func reportProgress(_ value: Double, source: PhotoSource, intent: UInt64, version: VersionID?, request: WorkspacePreviewRequest?) {
        guard value.isFinite, generation == intent, loadingGeneration == intent else { return }
        emit(.progress(max(0, min(1, value))), source: source, generation: intent, version: version, request: request)
    }

    /// The await spans completion. Concurrent calls supersede display intent immediately; queued
    /// obsolete requests are rejected after scheduler admission, before downloading an original.
    func request(source: PhotoSource, recipe: RecipeSnapshot?, workspaceRequest: WorkspacePreviewRequest? = nil) async {
        generation &+= 1
        displayIntent = nil
        currentJPEG = nil
        let intent = generation
        loadingGeneration = intent
        if self.source?.id != source.id || self.source?.resourceRevision != source.resourceRevision { displayedVersion = nil }
        self.source = source
        emit(.loading, source: source, generation: intent, version: recipe == nil ? .raw : nil, request: workspaceRequest)
        do {
            if let request = workspaceRequest {
                guard request.sourceID == source.id, request.sourceRevision == source.resourceRevision,
                      request.recipe == recipe else { throw ResourceError.resourceChanged }
            }
            if let recipe {
                let jpeg = try await scheduler.withPreview {
                    try await self.requireCurrent(intent)
                    return try await self.pool.withPreparedRAW(source: source, beforeMaterialize: { try await self.requireCurrent(intent) },
                        progress: { value in Task { await self.reportProgress(value, source: source, intent: intent, version: nil, request: workspaceRequest) } }) { raw in
                        try await self.requireCurrent(intent)
                        let context = try await self.camera.executionContext()
                        if let request = workspaceRequest, request.cameraContext != context { throw CameraServiceError.unsupportedContext }
                        let key = RenderKey(sourceID: raw.sourceID, sourceRevision: raw.sourceRevision, sourceSHA256: raw.sha256,
                            settingsDigest: recipe.settingsDigest, cameraContext: context, width: raw.metadata.recordedGeometry.width,
                            height: raw.metadata.recordedGeometry.height, orientation: raw.metadata.orientation,
                            policy: .fullSizeFineRecordedGeometry, quality: .fullResolutionFine)
                        let hit = await self.cache.lookup(key)
                        guard try await self.camera.executionContext() == context else { throw CameraServiceError.unsupportedContext }
                        try await self.requireCurrent(intent)
                        if let hit { return hit }
                        // Display cancellation must reach PhotoKit preparation, but an admitted
                        // native transaction owns its complete drain/quarantine/cleanup lifetime.
                        // Await this independent task even if the display caller is cancelled;
                        // the RAW lease and scheduler permit stay held until it actually returns.
                        let native = Task { try await self.camera.render(raw: raw, recipe: recipe, policy: .fullSizeFineRecordedGeometry) }
                        let result = try await native.value
                        let resultKey = result.key
                        guard resultKey.sourceID == raw.sourceID, resultKey.sourceRevision == raw.sourceRevision,
                              resultKey.sourceSHA256 == raw.sha256, resultKey.settingsDigest == recipe.settingsDigest,
                              resultKey.width == key.width, resultKey.height == key.height, resultKey.orientation == key.orientation,
                              resultKey.policy == key.policy, resultKey.quality == key.quality else {
                            try? FileManager.default.removeItem(at: result.fileURL)
                            throw CameraServiceError.invalidOutput
                        }
                        // A completed camera operation's actual context is authoritative. Store only
                        // its own validated key, even if the user's display intent changed meanwhile.
                        do { try await self.cache.store(result, key: result.key) }
                        catch {
                            try? FileManager.default.removeItem(at: result.fileURL)
                            throw error
                        }
                        guard let retained = await self.cache.lookup(result.key) else { throw RenderCacheError.missing }
                        return retained
                    }
                }
                guard generation == intent else { return }
                let current = try await camera.executionContext()
                guard generation == intent, current == jpeg.cameraContext,
                      workspaceRequest.map({ $0.cameraContext == current }) ?? true else { throw CameraServiceError.unsupportedContext }
                let file = try await cache.copyForDisplay(jpeg.key)
                guard generation == intent else { return }
                currentDisplayFile = file
                currentJPEG = jpeg
                displayedVersion = .preview(jpeg.key)
                emit(.ready(file.fileURL), source: source, generation: intent, version: displayedVersion, request: workspaceRequest)
            } else {
                try await showStored(.raw, source: source, intent: intent)
            }
        } catch {
            guard generation == intent else { return }
            emit(.failed(Self.failure(error)), source: source, generation: intent, version: displayedVersion, request: workspaceRequest)
        }
    }

    func selectStoredVersion(_ version: VersionID, source: PhotoSource, displayIntent: UInt64? = nil) async {
        self.source = source
        self.displayIntent = displayIntent
        currentJPEG = nil
        generation &+= 1
        let intent = generation
        loadingGeneration = intent
        emit(.loading, source: source, generation: intent, version: version, request: nil)
        do { try await showStored(version, source: source, intent: intent) }
        catch {
            guard generation == intent else { return }
            emit(.failed(Self.failure(error)), source: source, generation: intent, version: displayedVersion, request: nil)
        }
    }

    private func showStored(_ version: VersionID, source: PhotoSource, intent: UInt64) async throws {
        let file: DisplayFileLease
        let progress: @Sendable (Double) -> Void = { value in
            Task { await self.reportProgress(value, source: source, intent: intent, version: version, request: nil) }
        }
        switch version {
        case .raw:
            file = try await pool.withPreparedRAW(source: source, beforeMaterialize: { try await self.requireCurrent(intent) }, progress: progress) { raw in
                try await self.requireCurrent(intent)
                return try DisplayFileLease.copy(from: await self.rawRenderer.render(raw), geometry: ImageGeometry.raw(raw.metadata))
            }
        case .preview(let key):
            guard key.sourceID == source.id, key.sourceRevision == source.resourceRevision else { throw RenderCacheError.missing }
            file = try await cache.copyForDisplay(key)
        case .cameraJPEG, .saved:
            try requireCurrent(intent)
            file = try await storedDisplay(source, version, progress)
        }
        guard generation == intent else { return }
        currentDisplayFile = file
        displayedVersion = version
        emit(.ready(file.fileURL), source: source, generation: intent, version: version, request: nil)
    }

    func invalidate() {
        generation &+= 1
        source = nil
        displayedVersion = nil
        currentDisplayFile = nil
        currentJPEG = nil
        displayIntent = nil
        loadingGeneration = nil
    }

    private func requireCurrent(_ intent: UInt64) throws {
        try Task.checkCancellation()
        guard generation == intent else { throw CancellationError() }
    }
    private static func failure(_ error: any Error) -> PreviewFailure {
        switch error {
        case is RawDisplayError: .rawDisplayUnavailable
        case let error as ResourceError: .source(error)
        case let error as CameraServiceError: .camera(error)
        case let error as RenderCacheError: .cache(error)
        case is CancellationError: .cancelled
        default: .unavailable
        }
    }
}
