import FujiCameraCore
import SwiftUI
import Observation

/// The sole selection/reducer owner. Stream tasks retain services, never the model across next().
@MainActor @Observable final class AppModel {
    private(set) var state = WorkspaceState()
    private(set) var sources: [PhotoSource] = []
    private(set) var displayFile: DisplayFileLease?
    private(set) var preview: CameraJPEG?
    private(set) var savedVersions: [SavedVersion] = []
    private(set) var imageStatus: String?
    private var displayLoading: ImageLoadingState?
    /// Stored originals may finish while the selected recipe is still waiting for the camera.
    var imageLoading: ImageLoadingState? { displayLoading ?? (isLoadingPreview ? .loading : nil) }
    private(set) var message: String?
    private(set) var connectionError: String?
    private(set) var cameraError: String?
    private(set) var cameraResetError: String?
    private(set) var isResettingCamera = false
    private(set) var exportEvent: ExportEvent?
    private var unfinishedEvents: [UUID: ExportEvent] = [:]
    private var jobOrder: [UUID] = []
    private(set) var isLoadingLibrary = false
    private(set) var isRefreshing = false
    private(set) var isConnecting = false
    private(set) var isSubmitting = false
    var isLoadingPreview: Bool { state.isAwaitingRecipePreview }
    private(set) var isSuspended = false
    let environment: AppEnvironment
    let settings: AppSettings
    private(set) var wirelessState = WirelessConnectionState()
    private(set) var wirelessActionError: String?
    private(set) var importActionError: String?
    private(set) var importJournalIssue: ImportEvent?
    private var importEventsByJob: [UUID: ImportEvent] = [:]
    private(set) var isPreparingImport = false
    private(set) var isDisconnectingWireless = false
    var cameraBrowser: CameraBrowserModel { environment.wireless.browser }
    var importEvents: [ImportEvent] { importEventsByJob.values.sorted { $0.sequence < $1.sequence } }
    var importRecoveryEvents: [ImportEvent] { importEvents.filter { $0.captureIndex != nil || $0.recoveryRequired } }
    var cameraImportActive: Bool { isPreparingImport || importEvents.contains(where: \.isRunning) }
    var wirelessAvailable: Bool { environment.wireless.isEnabled }
    @ObservationIgnored private var wirelessActivity: WirelessActivity = .active
    @ObservationIgnored private var wirelessEpoch: UInt64 = 0
    @ObservationIgnored private var wirelessBackgroundTask: Task<Void, Never>?
    @ObservationIgnored private var browserLoadTask: Task<Void, Never>?
    @ObservationIgnored private var browserIntent: WirelessConnectionIntent?
    @ObservationIgnored private var browserLoanID: UUID?
    @ObservationIgnored private var retiringBrowserIntent: WirelessConnectionIntent?
    @ObservationIgnored private var browserFingerprints: [WirelessObjectDescriptor: ImportOriginalFingerprint] = [:]
    @ObservationIgnored private var browserBadgeTask: Task<Void, Never>?
    private struct BluetoothChoice {
        let id = UUID()
        var isCancelling = false
    }
    private var bluetoothChoice: BluetoothChoice?
    private var bluetoothChoiceActive: Bool { bluetoothChoice != nil }
    @ObservationIgnored private var wifiCommandActive = false
    @ObservationIgnored private var importCommand: (jobID: UUID?, task: Task<Void, Never>)?
    @ObservationIgnored private var importBinding: [UUID: ImportBinding] = [:]
    @ObservationIgnored private var importReconciliation: Task<Void, Never>?
    @ObservationIgnored private var importReconcilePending = false
    @ObservationIgnored private var receiptTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var recentImportMerges: [SourceID: UInt64] = [:]
    @ObservationIgnored private var importMergeRevision: UInt64 = 0
    @ObservationIgnored private var importJournalSequence: UInt64 = 0
    private struct ImportBinding {
        let runID: UUID
        let intent: WirelessConnectionIntent?
        var lastEvent: UInt64 = 0
    }
    @ObservationIgnored private var started = false
    @ObservationIgnored private var streams: [Task<Void, Never>] = []
    @ObservationIgnored private var displayTask: Task<Void, Never>?
    @ObservationIgnored private var sceneTask: Task<Void, Never>?
    @ObservationIgnored private var submissionTask: Task<UUID, Error>?
    @ObservationIgnored private var libraryGeneration: UInt64 = 0
    @ObservationIgnored private var establishedSourceIDs: Set<SourceID> = []
    @ObservationIgnored private var observedImportInsertions: Set<SourceID> = []
    @ObservationIgnored private var sourceReplacements: [SourceID: SourceID] = [:]
    @ObservationIgnored private var displayIntent: UInt64 = 0
    @ObservationIgnored private var cameraEventGeneration: UInt64 = 0
    @ObservationIgnored private var importedSessions: Set<UUID> = []
    @ObservationIgnored private var recipeImportTask:Task<ImportedRecipeCollection,Error>?
    @ObservationIgnored private var recipeRequestToken:UUID?
    @ObservationIgnored private var recipeLifecycleRevision:UInt64 = 0
    @ObservationIgnored private var pendingImportReady:CameraSession?
    @ObservationIgnored private var pendingImportTerminal:CameraState?
    @ObservationIgnored private var awaitingImportTerminal = false
    @ObservationIgnored private var cameraResetCallActive = false
    @ObservationIgnored private var cameraResetReadyAdopted = false
    @ObservationIgnored private var cameraResetAwaitingTerminal = false
    @ObservationIgnored private var cameraResetDeferredDisconnect = false
    @ObservationIgnored private var cameraResetRevision: UInt64 = 0
    @ObservationIgnored private var contextTask: Task<Void, Never>?
    @ObservationIgnored private var versionRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var versionRefreshSource: SourceID?
    @ObservationIgnored private var versionRefreshWorker: UInt64 = 0
    @ObservationIgnored private var versionRefreshGeneration: UInt64 = 0
    @ObservationIgnored private var recoverySequence: UInt64 = 0
    @ObservationIgnored private var recoveryNeeded = false
    @ObservationIgnored private var recovering = false
    @ObservationIgnored private var previousIdle: Bool?
    @ObservationIgnored private var automaticConnectionTask: Task<Void, Never>?
    @ObservationIgnored private let connectionRetryWait: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var cameraAuthorizationDenied = false
    @ObservationIgnored private var automaticConnectionEnabled = true
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var sceneRevision: UInt64 = 0
    @ObservationIgnored private var displayRequest: WorkspacePreviewRequest?
    @ObservationIgnored private var displayFailure: String?
    private struct AvailableDisplay {
        let sourceID: SourceID, revision: String
        let version: VersionID
        let file: DisplayFileLease
    }
    @ObservationIgnored private var availableDisplay: AvailableDisplay?
    @ObservationIgnored private var detectedCompatibility: [OriginalIdentity: RAWCompatibility] = [:]
    @ObservationIgnored private var photoFilterTask: Task<Void, Never>?
    @ObservationIgnored private var photoFilterWorkerID: UUID?
    @ObservationIgnored private var photoFilterWorkerCamera: PhotoTrayFilterCamera?
    @ObservationIgnored private var photoFilterWorkerSources: Set<OriginalIdentity> = []

    #if DEBUG
    /// Read-only lifecycle continuity for opt-in acceptance instrumentation.
    var validationScene: (revision: UInt64, foreground: Bool) { (sceneRevision, foreground) }
    @ObservationIgnored var validationDropDiscoveryUpdates = false
    @ObservationIgnored var validationDiscoveryStateRead: FixtureBarrier?
    #endif

    init(environment: AppEnvironment, settings: AppSettings? = nil,
         connectionRetryWait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.environment = environment; self.connectionRetryWait = connectionRetryWait
        self.settings = settings ?? AppSettings()
    }
    var imageStatusIsFailure: Bool { displayFailure != nil }
    var canResetCameraConnection: Bool {
        guard !isResettingCamera, !isConnecting, !isRefreshing, !isSubmitting,
              !isLoadingPreview, !state.wirelessRestrictsUSB, !bluetoothChoiceActive,
              state.activeJobID == nil, foreground, !isSuspended else { return false }
        if case .busy = state.cameraState { return false }
        return true
    }
    /// Keep the displayed file's identity until its replacement is ready, even after selection moves.
    var imageIdentity: (sourceID: SourceID, version: VersionID)? {
        guard displayFile != nil, let availableDisplay else { return nil }
        return (availableDisplay.sourceID, availableDisplay.version)
    }
    private var hasCurrentSourceDisplay: Bool {
        availableDisplay?.sourceID == state.viewedSourceID && availableDisplay?.revision == state.viewedSourceRevision
            && displayFile != nil
    }
    deinit {
        streams.forEach { $0.cancel() }; displayTask?.cancel(); contextTask?.cancel(); versionRefreshTask?.cancel()
        automaticConnectionTask?.cancel()
        photoFilterTask?.cancel()
        browserLoadTask?.cancel()
        browserBadgeTask?.cancel()
        importCommand?.task.cancel()
        importReconciliation?.cancel()
        receiptTasks.values.forEach { $0.cancel() }
    }

    var progressEvents: [ExportEvent] {
        var values = jobOrder.compactMap { unfinishedEvents[$0] }
        if let exportEvent, !values.contains(where: { $0.jobID == exportEvent.jobID }) { values.append(exportEvent) }
        return values
    }

    func start(automaticallyConnect: Bool = true) async {
        guard !started else { return }; started = true
        automaticConnectionEnabled = automaticallyConnect
        let library = await environment.reader.changes()
        let camera = await environment.camera.states()
        let previews = await environment.preview.events()
        let exports = await environment.exports.events()
        let compatibility = await environment.originals.compatibilityChanges()
        streams = [
            Task { [weak self] in for await snapshot in compatibility { guard !Task.isCancelled else { break }; self?.compatibilityChanged(snapshot) } },
            Task { [weak self] in for await event in library { guard !Task.isCancelled else { break }; await self?.libraryChanged(event) } },
            Task { [weak self] in for await event in camera { guard !Task.isCancelled else { break }; self?.cameraChanged(event) } },
            Task { [weak self] in for await event in previews { guard !Task.isCancelled else { break }; self?.previewChanged(event) } },
            Task { [weak self] in for await event in exports { guard !Task.isCancelled else { break }; await self?.exportChanged(event) } }
        ]
        if wirelessAvailable { await observeWireless() }
        startAutomaticConnection()
        do {
            let recipes = try await environment.catalog.latestRecipes()
            let slots = try await environment.catalog.latestRecipeSlots()
            reduce(.recipesLoaded(recipes,slots:slots))
        } catch { message = Self.explain(error) }
        do { reduce(.phoneRecipesLoaded(try await environment.catalog.phoneRecipes())) }
        catch { message = Self.explain(error) }
        await reloadLibrary()
        await recoverWhenIdle()
        if wirelessAvailable, wirelessActivity == .active { await reconcileImports() }
    }

    func send(_ action: WorkspaceAction) {
        reduce(action)
    }

    private func reduce(_ action: WorkspaceAction) {
        defer { refreshPhotoFilterWorker() }
        let previousSource = state.viewedSourceID, previousVersion = state.displayedVersion
        let previousRecipe = state.selectedRecipe
        let previousRevision = state.viewedSourceRevision
        let effects = state.reduce(action)
        if let availableDisplay,
           !sources.contains(where: { $0.id == availableDisplay.sourceID && $0.resourceRevision == availableDisplay.revision }) {
            displayFile = nil; self.availableDisplay = nil
        }
        let request = effects.compactMap { effect -> WorkspacePreviewRequest? in
            if case .requestPreview(let request) = effect { return request }; return nil
        }.first
        let explicitDisplay: Bool = switch action {
        case .sourceTapped, .versionSelected, .recipeSelected, .phoneRecipeSelected, .viewImported: true
        case .phoneRecipeDeleted: previousRecipe != nil && state.selectedRecipe == nil
        case .phoneRecipeUpdated: previousRecipe != state.selectedRecipe
        case .cameraChanged: displayRequest != nil && previousRecipe != nil && state.selectedRecipe == nil
        case .recipeImportStarted: displayRequest != nil
        default: false
        }
        if request != nil || explicitDisplay || previousSource != state.viewedSourceID || previousVersion != state.displayedVersion || previousRevision != state.viewedSourceRevision {
            if case .previewCompleted = action { return }
            requestDisplay(request)
        }
        // Manual drawer collapse is fulfilled by WorkspaceView after final grid bounds settle.
    }

    private func cancelPhotoFilterChecks() {
        photoFilterTask?.cancel(); photoFilterTask = nil; photoFilterWorkerID = nil
        photoFilterWorkerCamera = nil; photoFilterWorkerSources = []
    }

    private func refreshPhotoFilterWorker() {
        guard foreground, !isSuspended, state.photoFilter == .compatibleWithCamera,
              let camera = state.photoFilterCamera, let support = state.cameraSupport else {
            cancelPhotoFilterChecks(); return
        }
        let identities = Set(sources.map(OriginalIdentity.init))
        if photoFilterWorkerCamera != camera || photoFilterWorkerSources != identities {
            cancelPhotoFilterChecks()
        }
        guard photoFilterTask == nil, sources.contains(where: state.photoFilterNeedsAssessment) else { return }
        let id = UUID(), pool = environment.originals
        photoFilterWorkerID = id; photoFilterWorkerCamera = camera; photoFilterWorkerSources = identities
        photoFilterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self?.photoFilterWorkerID == id,
                      let source = self?.sources.first(where: { self?.state.photoFilterNeedsAssessment($0) == true }) else { break }
                let result: PhotoTrayAssessment
                do {
                    let assessment = try await pool.assess(source: source, for: support)
                    result = assessment == .supported(model: support.model) ? .compatible : .incompatible
                } catch {
                    if Task.isCancelled || error is CancellationError { break }
                    result = .unavailable
                }
                guard !Task.isCancelled, self?.photoFilterWorkerID == id else { break }
                self?.reduce(.photoFilterAssessed(source, camera: camera, result: result))
                // Each source releases the resource permit before the next check, allowing
                // queued viewer/export work to run. No USB work is needed for assessment.
                await Task.yield()
            }
            if self?.photoFilterWorkerID == id {
                self?.photoFilterTask = nil; self?.photoFilterWorkerID = nil
            }
        }
    }

    private func requestDisplay(_ request: WorkspacePreviewRequest?) {
        displayTask?.cancel()
        displayIntent &+= 1
        let intent = displayIntent
        // Supersede intent in the coordinator; an already-active camera operation must drain.
        displayRequest = request; displayFailure = nil
        if let availableDisplay, let selected = state.viewedSourceID, state.displayedVersion != nil,
           sources.contains(where: { $0.id == availableDisplay.sourceID && $0.resourceRevision == availableDisplay.revision }),
           availableDisplay.sourceID != selected || (hasCurrentSourceDisplay && (request != nil || availableDisplay.version == state.displayedVersion)) {
            displayFile = availableDisplay.file
            if request != nil, hasCurrentSourceDisplay { state.reduce(.previewFallback(availableDisplay.version)) }
        } else {
            displayFile = nil; availableDisplay = nil
        }
        imageStatus = "Loading image…"
        displayLoading = .loading
        if preview?.sourceID != state.viewedSourceID || preview?.sourceRevision != state.viewedSourceRevision { preview = nil }
        guard let source = sources.first(where: { $0.id == state.viewedSourceID }), let version = state.displayedVersion else {
            savedVersions = []; imageStatus = nil; displayLoading = nil
            let coordinator = environment.preview
            displayTask = Task { await coordinator.invalidate() }; return
        }
        let coordinator = environment.preview, resolver = environment.resolver
        let showQueuedOriginal: Bool
        if case .busy = state.cameraState { showQueuedOriginal = source.originalResources.jpeg != nil }
        else { showQueuedOriginal = false }
        // Foreground recovery reloads Photos before reopening work. A selected image is
        // still pending during that interval; an empty viewer must keep its loading state.
        guard !isSuspended else {
            displayTask = Task { await coordinator.invalidate() }; return
        }
        displayTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await coordinator.invalidate()
            guard let self else { return }
            await self.refreshVersions()
            guard !Task.isCancelled, self.displayIntent == intent else { return }
            if let request {
                await withTaskGroup(of: Void.self) { group in
                    // Stored JPEGs can appear while the prioritized preview waits for the
                    // camera. Intent checks keep this fallback from replacing a ready preview.
                    if showQueuedOriginal {
                        group.addTask { [weak self] in
                            guard let file = try? await resolver.resolve(source: source, version: .cameraJPEG).lease else { return }
                            await self?.showQueuedPreviewOriginal(file, source: source, request: request, intent: intent)
                        }
                    }
                    await coordinator.request(source: source, recipe: request.recipe, workspaceRequest: request)
                    group.cancelAll()
                }
            }
            else { await coordinator.selectStoredVersion(version, source: source, displayIntent: intent) }
        }
    }

    private func showQueuedPreviewOriginal(_ file: DisplayFileLease, source: PhotoSource, request: WorkspacePreviewRequest, intent: UInt64) {
        guard !Task.isCancelled, !isSuspended, displayIntent == intent, displayRequest == request,
              state.acceptsPreview(request), state.viewedSourceID == source.id,
              state.viewedSourceRevision == source.resourceRevision else { return }
        state.reduce(.previewFallback(.cameraJPEG))
        displayFile = file
        availableDisplay = AvailableDisplay(sourceID: source.id, revision: source.resourceRevision, version: .cameraJPEG, file: file)
        displayLoading = nil; imageStatus = nil
    }

    private func previewChanged(_ event: PreviewEvent) {
        guard !isSuspended, event.sourceID == state.viewedSourceID else { return }
        if let request = event.workspaceRequest {
            guard displayRequest == request, request.sourceRevision == state.viewedSourceRevision else { return }
            guard case .ready = event.state, let jpeg = event.jpeg, case .preview(let key) = event.version else {
                displayLoading = ImageLoadingState(event.state)
                if case .failed(let failure) = event.state, state.selectedRecipe == request.recipe {
                    // A previous native operation can require attention before a queued
                    // preview is admitted. Keep browsing without reporting a second error.
                    if case .camera(.notReady) = failure, case .attentionRequired = state.cameraState,
                       !state.acceptsPreview(request) {
                        displayLoading = nil; imageStatus = displayFailure
                        if !hasCurrentSourceDisplay { resolveFallbackOriginal() }
                        return
                    }
                    if case .camera(.unsupportedSource) = failure,
                       request.cameraContext == state.currentCameraExecutionContext,
                       let camera = state.photoFilterCamera,
                       let source = sources.first(where: { $0.id == request.sourceID }) {
                        state.reduce(.photoFilterAssessed(source, camera: camera, result: .incompatible))
                    }
                    displayFailure = previewMessage(failure); imageStatus = displayFailure
                    state.reduce(.previewInterrupted)
                    if !hasCurrentSourceDisplay { resolveFallbackOriginal() }
                } else {
                    imageStatus = Self.loadingMessage(event.state)
                }
                return
            }
            guard state.acceptsPreview(request) else { return }
            state.reduce(.previewCompleted(request: request, key: key))
            guard state.displayedVersion == .preview(key) else { return }
            preview = jpeg
        } else {
            guard event.displayIntent == displayIntent else { return }
            if case .ready = event.state, event.version != state.displayedVersion { return }
        }
        switch event.state {
        case .ready:
            displayLoading = nil
            displayFile = event.displayFile; imageStatus = displayFailure
            if let file = event.displayFile, let version = event.version, let revision = state.viewedSourceRevision {
                availableDisplay = AvailableDisplay(sourceID: event.sourceID, revision: revision, version: version, file: file)
            }
        case .loading, .progress:
            displayLoading = ImageLoadingState(event.state)
            imageStatus = displayFailure ?? Self.loadingMessage(event.state)
        case .failed(let failure):
            displayLoading = nil
            if !hasCurrentSourceDisplay { displayFile = nil; availableDisplay = nil }
            displayFailure = previewMessage(failure); imageStatus = displayFailure
        }
    }

    /// A fallback is stored content only. It must never retry the failed camera request.
    private func resolveFallbackOriginal() {
        guard let source = sources.first(where: { $0.id == state.viewedSourceID }) else { return }
        let version: VersionID = source.originalResources.jpeg == nil ? .raw : .cameraJPEG
        state.reduce(.previewFallback(version))
        displayLoading = .loading
        let coordinator = environment.preview, intent = displayIntent
        displayTask = Task { await coordinator.selectStoredVersion(version, source: source, displayIntent: intent) }
    }

    var detail: ZoomPhotoView.DetailProvider? {
        guard hasCurrentSourceDisplay, let source = sources.first(where: { $0.id == state.viewedSourceID }), let file = displayFile else { return nil }
        if state.displayedVersion == .raw {
            let resolver = environment.resolver
            return { region, size in try await resolver.rawDetail(source: source, topLeftRegion: region, maximumDimension: size) }
        }
        let renderer = environment.jpegDetail
        return { region, size in try await renderer.detail(file: file, topLeftRegion: region, maximumDimension: size) }
    }

    func reloadLibrary() async {
        libraryGeneration &+= 1; let generation = libraryGeneration
        let importsAtStart = importMergeRevision
        var establishedIDs = establishedSourceIDs
        var readCatalogIDs = false
        func visibility() async -> ImportPhotoVisibility {
            let eligibility = await importPhotoVisibility()
            if eligibility.needsEstablishedIDs && !readCatalogIDs {
                if let known = try? await environment.catalog.knownSourceIDs() { establishedIDs.formUnion(known) }
                readCatalogIDs = true
            }
            return eligibility
        }
        isLoadingLibrary = true
        defer { if libraryGeneration == generation { isLoadingLibrary = false } }
        let access = await environment.reader.requestAccess()
        guard generation == libraryGeneration else { return }
        if access != .full && access != .limited {
            sources = []; reduce(.libraryUpdated(sources: [], access: access))
            await environment.exports.pauseActiveWork()
            return
        }
        await adoptVerifiedReplacements()
        guard generation == libraryGeneration else { return }
        var discovered: [SourceID: PhotoSource] = [:]
        do {
            for try await batch in await environment.reader.sources() {
                // The Photos batch can include an asset whose entire save occurred
                // during discovery. Only evidence read after receiving it is current.
                let importPhotos = await visibility()
                guard generation == libraryGeneration else { return }
                for source in batch where sourceReplacements[source.id] == nil
                    && importPhotos.allows(source, establishedIDs: establishedIDs) {
                    discovered[source.id] = knownCompatibility(source)
                }
                // Batches are additions. Keep the existing permitted index until the full pass ends.
                var merged = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
                merged.merge(discovered, uniquingKeysWith: { _, new in new })
                sources = Self.sorted(Array(merged.values))
                reduce(.libraryUpdated(sources: sources, access: access))
            }
            let importPhotos = await visibility()
            guard generation == libraryGeneration else { return }
            for source in sources where (recentImportMerges[source.id] ?? 0) > importsAtStart {
                discovered[source.id] = source
            }
            discovered = discovered.filter { importPhotos.allows($0.value, establishedIDs: establishedIDs) }
            let removed = Set(sources.map(\.id)).subtracting(discovered.keys)
            sources = Self.sorted(discovered.values.map(knownCompatibility))
            reduce(.libraryUpdated(sources: sources, access: access))
            if !removed.isEmpty { await environment.exports.pauseActiveWork() }
            guard generation == libraryGeneration else { return }
            let catalogSources = sources
            try await environment.catalog.upsertSources(catalogSources)
            establishedSourceIDs.formUnion(catalogSources.map(\.id))
            await refreshVersions()
        } catch { if generation == libraryGeneration { message = Self.explain(error) } }
    }

    private func knownCompatibility(_ source: PhotoSource) -> PhotoSource {
        var current = source
        current.compatibility = detectedCompatibility[OriginalIdentity(source)] ?? source.compatibility
        return current
    }
    private func compatibilityChanged(_ snapshot: [OriginalIdentity: RAWCompatibility]) {
        detectedCompatibility = snapshot
        sources = sources.map(knownCompatibility)
        reduce(.libraryUpdated(sources: sources, access: state.libraryAccess))
    }

    private func libraryChanged(_ event: LibraryChange) async {
        if wirelessAvailable, !event.authorizationChanged, event.removedIDs.isEmpty,
           !event.insertedIDs.isEmpty, event.changedIDs == event.insertedIDs,
           event.insertedIDs.isDisjoint(with: observedImportInsertions),
           let insertion = await currentImportInsertion(event.insertedIDs) {
            observedImportInsertions.formUnion(event.insertedIDs)
            // Under limited access the first appearance of a known placeholder
            // may be the grant that makes its saved originals readable.
            if insertion == .pendingVerification, event.accessScopeChanged, wirelessActivity != .background {
                await reconcileImports(afterPhotoVisibilityChange: true)
            }
            return
        }
        // A later grant can reinsert the same Photos asset. Treat that as a library
        // scope change even if the first insertion was owned by the import path.
        observedImportInsertions.formUnion(event.removedIDs)
        await adoptVerifiedReplacements()
        var thumbnailIDs = event.changedIDs.union(event.removedIDs)
        if event.accessScopeChanged { thumbnailIDs.formUnion(sources.map(\.id)) }
        environment.thumbnails.invalidate(sourceIDs: thumbnailIDs)
        if !hasCurrentSourceDisplay, event.accessScopeChanged || !event.removedIDs.isEmpty {
            displayFile = nil; availableDisplay = nil
        }
        sources.removeAll { event.removedIDs.contains($0.id) }
        reduce(.libraryUpdated(sources: sources, access: state.libraryAccess))
        if !event.removedIDs.subtracting(sourceReplacements.keys).isEmpty { await environment.exports.pauseActiveWork() }
        for id in event.removedIDs {
            try? await environment.catalog.setAvailability(assetID: id, availability: .inaccessible)
            await environment.cache.invalidate(sourceID: id)
        }
        reduce(.libraryUpdated(sources: sources, access: state.libraryAccess))
        await reloadLibrary()
        refreshBrowserBadges()
        recoveryNeeded = true; await recoverWhenIdle()
        if wirelessAvailable, wirelessActivity == .active, event.accessScopeChanged {
            await reconcileImports(afterPhotoVisibilityChange: true)
        }
    }

    private func adoptVerifiedReplacements() async {
        let scope = libraryGeneration
        do {
            let replacements = try await environment.exports.sourceReplacements()
            var accessible: [SourceID: SourceID] = [:]
            for (previous, id) in replacements.sorted(by: { $0.key < $1.key }) {
                var replacement: PhotoSource
                do { replacement = try await environment.reader.source(id: id) }
                catch ResourceError.inaccessibleAsset { continue }
                catch ResourceError.authorization { continue }
                guard scope == libraryGeneration else { return }
                accessible[previous] = id
                if sourceReplacements[previous] == id { continue }
                if let original = sources.first(where: { $0.id == previous }) { replacement.compatibility = original.compatibility }
                try await environment.catalog.replaceSource(previous, with: replacement)
                establishedSourceIDs.insert(replacement.id)
                guard scope == libraryGeneration else { return }
                sourceReplacements[previous] = id
                sources.removeAll { $0.id == previous || $0.id == id }
                sources.append(replacement); sources = Self.sorted(sources)
                reduce(.sourceReplaced(previous, with: replacement))
            }
            if scope == libraryGeneration { sourceReplacements = accessible }
        } catch { message = Self.explain(error) }
    }

    private func cameraChanged(_ event: CameraState) {
        guard !isSuspended else { return }
        // Session cleanup may deliver DISCONNECTED after connect() reports denial.
        // Keep the Settings action until the next foreground authorization attempt.
        if cameraAuthorizationDenied, event == .disconnected { return }
        if case .attentionRequired(_, let message) = event {
            cameraError = message
            if displayFailure != nil { displayFailure = message; imageStatus = message }
        }
        // Keep the verified context and selection while an explicit reset closes
        // and reopens the native session. READY adopts the replacement context.
        if isResettingCamera || cameraResetAwaitingTerminal {
            switch event {
            case .opening, .discovering, .sessionOpen: return
            case .disconnected where cameraResetCallActive:
                cameraResetDeferredDisconnect = true
                return
            default: break
            }
        }
        if case .disconnected = event {
            let resetTerminal = cameraResetAwaitingTerminal
            cameraResetAwaitingTerminal = false
            if isResettingCamera {
                isResettingCamera = false
                reduce(.cameraResetChanged(false))
                cameraResetError = "The camera disconnected during reset."
            } else if !resetTerminal {
                cameraError = nil; cameraResetError = nil
            }
        }
        cameraEventGeneration &+= 1
        let token = cameraEventGeneration
        switch event {
        case .ready, .attentionRequired, .disconnected, .authorizationDenied, .wrongMode, .recoverableError:
            awaitingImportTerminal = false
            cameraResetAwaitingTerminal = false
            cameraResetDeferredDisconnect = false
        default: break
        }
        if isRefreshing {
            switch event {
            case .ready(let session):pendingImportReady=session;return
            case .busy,.opening,.discovering,.sessionOpen,.authorizationRequired:return
            default:pendingImportTerminal=event;return
            }
        }
        switch event {
        case .attentionRequired(let session, _):
            contextTask?.cancel()
            let context = state.currentCameraExecutionContext
            if let context { reduce(.cameraChanged(event, context: context)) }
            if context?.generation == session.generation, state.cameraSupport != nil { return }
            let camera = environment.camera
            contextTask = Task { [weak self] in
                do {
                    let context = try await camera.executionContext()
                    let support = try await camera.support(for: context)
                    guard !Task.isCancelled, let self, self.cameraEventGeneration == token,
                          !self.isSuspended, context.generation == session.generation else { return }
                    self.reduce(.cameraChanged(event, context: context))
                    self.reduce(.cameraSupportVerified(context, support))
                } catch {
                    guard !Task.isCancelled, let self, self.cameraEventGeneration == token, !self.isSuspended else { return }
                    self.reduce(.cameraChanged(event, context: nil))
                }
            }
        case .ready(let session), .busy(let session):
            if let context = state.currentCameraExecutionContext, context.generation == session.generation {
                if case .ready = event {
                    cameraError = nil; cameraResetError = nil; connectionError = nil
                    cameraResetReadyAdopted = true; finishCameraResetIfReady()
                }
                reduce(.cameraChanged(event, context: context))
                return
            }
            // Only fresh READY verifies context. Busy from our own operation never queues a
            // getter behind that operation or replays a delayed state into the reducer.
            guard case .ready = event, !isSuspended else { return }
            let camera = environment.camera
            contextTask?.cancel()
            contextTask = Task { [weak self] in
                do {
                    let context = try await camera.executionContext()
                    let support = try await camera.support(for:context)
                    guard !Task.isCancelled, let self, self.cameraEventGeneration == token, !self.isSuspended,
                          context.generation == session.generation else { return }
                    self.cameraError = nil; self.cameraResetError = nil; self.connectionError = nil
                    self.reduce(.cameraChanged(event, context: context))
                    self.reduce(.cameraSupportVerified(context,support))
                    self.cameraResetReadyAdopted = true; self.finishCameraResetIfReady()
                    if !self.isResettingCamera, support.capabilities.recipeImport == .supported,
                        self.importedSessions.insert(context.sessionIdentity).inserted { await self.refreshRecipes() }
                } catch { }
            }
        default:
            contextTask?.cancel()
            if isLoadingPreview {
                state.reduce(.previewInterrupted)
            }
            reduce(.cameraChanged(event, context: nil))
        }
    }

    func connect() async {
        guard !Task.isCancelled, !isConnecting, foreground, !isSuspended,
              !state.wirelessRestrictsUSB, !bluetoothChoiceActive,
              !cameraAuthorizationDenied, !isRefreshing, !isResettingCamera,
              !awaitingImportTerminal,
              cameraError == nil, cameraResetError == nil, state.currentCameraExecutionContext == nil else { return }
        // READY may precede the asynchronous execution-context lookup.
        switch state.cameraState { case .ready, .busy, .attentionRequired: return; default: break }
        isConnecting = true
        defer { isConnecting = false }
        do { try await environment.camera.connect(); connectionError = nil }
        catch {
            guard !Task.isCancelled else { return }
            switch error {
            case CameraServiceError.transport(.authorizationDenied):
                cameraAuthorizationDenied = true
                reduce(.cameraChanged(.authorizationDenied, context: nil))
                connectionError = nil
            case CameraServiceError.transport(.timeout), CameraServiceError.transport(.notConnected),
                 CameraServiceError.cancelled, WirelessFailure.cameraBusy, is CancellationError:
                connectionError = nil // An absent camera is normal while browsing photos.
            default: connectionError = Self.explain(error)
            }
        }
    }

    func resetCameraConnection() async {
        guard canResetCameraConnection else { return }
        isResettingCamera = true
        cameraResetRevision &+= 1
        let revision = cameraResetRevision
        cameraResetCallActive = true; cameraResetReadyAdopted = false
        cameraResetAwaitingTerminal = true
        cameraResetDeferredDisconnect = false
        cameraResetError = nil
        reduce(.cameraResetChanged(true))
        await environment.preview.invalidate()
        guard revision == cameraResetRevision, !isSuspended else { return }
        do {
            try await environment.camera.resetConnection()
            guard revision == cameraResetRevision, !isSuspended else { return }
            cameraResetCallActive = false
            cameraResetDeferredDisconnect = false
            finishCameraResetIfReady()
            if !isResettingCamera, let context = state.currentCameraExecutionContext,
               state.cameraSupport?.capabilities.recipeImport == .supported,
               importedSessions.insert(context.sessionIdentity).inserted { await refreshRecipes() }
        }
        catch {
            guard revision == cameraResetRevision, !isSuspended else { return }
            cameraResetCallActive = false; isResettingCamera = false
            reduce(.cameraResetChanged(false))
            let deferredDisconnect = cameraResetDeferredDisconnect
            cameraResetDeferredDisconnect = false
            if case WirelessFailure.cameraBusy = error {
                // No native reset started. A concurrent handoff may already have closed USB.
                cameraResetAwaitingTerminal = false
                if deferredDisconnect { cameraChanged(.disconnected) }
                return
            }
            cameraResetError = "Reset failed: \(Self.explain(error))"
        }
    }

    private func finishCameraResetIfReady() {
        guard isResettingCamera, cameraResetReadyAdopted, !cameraResetCallActive else { return }
        isResettingCamera = false
        reduce(.cameraResetChanged(false))
    }

    private func startAutomaticConnection() {
        guard started, automaticConnectionEnabled, foreground, !isSuspended, automaticConnectionTask == nil,
              wirelessState.selectedCameraID == nil, !bluetoothChoiceActive, !state.wirelessRestrictsUSB else { return }
        let wait = connectionRetryWait
        automaticConnectionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.connect()
                guard !Task.isCancelled else { return }
                // Discovery already reacts to USB attachment while connect is pending.
                // Only a completed attempt reaches this delay; opens never overlap.
                do { try await wait(.seconds(3)) } catch { return }
            }
        }
    }

    private func stopAutomaticConnection() {
        automaticConnectionTask?.cancel(); automaticConnectionTask = nil
    }

    func setAutomaticUSBDiscoveryEnabled(_ enabled: Bool) {
        automaticConnectionEnabled = enabled
        if enabled { startAutomaticConnection() }
        else { stopAutomaticConnection() }
    }

    func refreshRecipes() async {
        guard !isSuspended, !isResettingCamera, !state.wirelessRestrictsUSB, !bluetoothChoiceActive,
              state.activeJobID == nil, !isSubmitting, cameraError == nil, cameraResetError == nil else { return }
        let operation:Task<ImportedRecipeCollection,Error>
        if let active=recipeImportTask { operation=active }
        else {
            guard state.currentCameraExecutionContext != nil else {
                reduce(.recipeRefreshFailed("Connect a supported Fujifilm camera to import recipes."));return
            }
            guard state.cameraSupport?.capabilities.recipeImport == .supported else {
                reduce(.recipeRefreshFailed("Recipe import is unavailable for this camera."));return
            }
            let camera=environment.camera
            pendingImportReady=nil;pendingImportTerminal=nil
            reduce(.recipeImportStarted)
            operation=Task { try await camera.importRecipes() }
            recipeImportTask=operation
        }
        // Concurrent refresh callers share one owned read. Only the newest caller can
        // commit/adopt its receipt; a second tap never repeats the backup transaction.
        let request=UUID(),lifecycle=recipeLifecycleRevision
        recipeRequestToken=request;isRefreshing=true
        defer {
            if recipeRequestToken == request {
                isRefreshing=false;recipeImportTask=nil;recipeRequestToken=nil;pendingImportReady=nil;pendingImportTerminal=nil
            }
        }
        var cameraImportFinished = false
        do {
            let collection=try await operation.value
            cameraImportFinished = true
            guard recipeRequestIsCurrent(request,lifecycle:lifecycle) else { return }
            guard try await environment.camera.executionContext() == collection.context else { throw CameraServiceError.unsupportedContext }
            guard recipeRequestIsCurrent(request,lifecycle:lifecycle) else { return }
            let support=try await environment.camera.support(for:collection.context)
            guard support == collection.support,recipeRequestIsCurrent(request,lifecycle:lifecycle) else { return }
            try await environment.catalog.replaceRecipes(collection)
            guard recipeRequestIsCurrent(request,lifecycle:lifecycle) else { return }
            guard try await environment.camera.executionContext() == collection.context else { throw CameraServiceError.unsupportedContext }
            guard recipeRequestIsCurrent(request,lifecycle:lifecycle) else { return }
            importedSessions.insert(collection.context.sessionIdentity)
            reduce(.recipesImported(collection))
            if let ready=pendingImportReady,ready.generation == collection.context.generation {
                reduce(.cameraChanged(.ready(ready),context:collection.context))
            }
        } catch {
            if recipeRequestIsCurrent(request,lifecycle:lifecycle) {
                let attentionPending: Bool
                if case .attentionRequired? = pendingImportTerminal { attentionPending = true }
                else { attentionPending = false }
                if !cameraImportFinished || attentionPending {
                    let context = try? await environment.camera.executionContext()
                    let support: VerifiedCameraSupport?
                    if let context { support = try? await environment.camera.support(for: context) }
                    else { support = nil }
                    guard recipeRequestIsCurrent(request,lifecycle:lifecycle) else { return }
                    if let terminal = pendingImportTerminal ?? pendingImportReady.map(CameraState.ready) {
                        awaitingImportTerminal = false
                        switch terminal {
                        case .ready, .busy, .attentionRequired:
                            reduce(.cameraChanged(terminal,context:context))
                            if let context, let support { reduce(.cameraSupportVerified(context,support)) }
                        default: reduce(.cameraChanged(terminal, context: nil))
                        }
                    } else {
                        // The service owns connection recovery. Its stream can deliver
                        // the terminal state after the import's thrown error resumes us.
                        awaitingImportTerminal = true
                    }
                    reduce(.recipeRefreshFailed(Self.explain(error)))
                    return
                }
                // A failed receipt commit must not leave a live service context behind
                // the app's retired context. Close it so Connect can start a fresh
                // attempt; never publish the collection whose persistence failed.
                let denied = pendingImportTerminal == .authorizationDenied
                await environment.camera.disconnect()
                guard recipeRequestIsCurrent(request,lifecycle:lifecycle) else { return }
                let terminal = denied ? CameraState.authorizationDenied : (pendingImportTerminal ?? .disconnected)
                if terminal == .authorizationDenied { cameraAuthorizationDenied=true }
                reduce(.cameraChanged(terminal,context:nil))
                reduce(.recipeRefreshFailed(Self.explain(error)))
            }
        }
    }
    private func recipeRequestIsCurrent(_ request:UUID,lifecycle:UInt64) -> Bool {
        recipeRequestToken == request && recipeLifecycleRevision == lifecycle && !isSuspended && !Task.isCancelled
    }

    func copyRecipeToPhone(id: UUID) async -> Bool {
        guard let recipe = state.recipes.first(where: { $0.id == id }) else { return false }
        do {
            let copy = try await environment.catalog.copyRecipeToPhone(recipe)
            if !state.phoneRecipes.contains(where: { $0.id == copy.id }) {
                reduce(.phoneRecipesLoaded(state.phoneRecipes + [copy]))
            }
            message = nil
            return true
        } catch {
            message = Self.explain(error)
            return false
        }
    }

    func deletePhoneRecipe(id: UUID) async -> Bool {
        guard state.phoneRecipes.contains(where: { $0.id == id }) else { return false }
        do {
            try await environment.catalog.deletePhoneRecipe(id: id)
            reduce(.phoneRecipeDeleted(id))
            message = nil
            return true
        } catch {
            message = Self.explain(error)
            return false
        }
    }

    func updatePhoneRecipe(_ draft: PhoneRecipeDraft) async throws {
        do {
            let updated = try await environment.catalog.updatePhoneRecipe(draft)
            reduce(.phoneRecipeUpdated(updated))
            message = nil
        } catch {
            message = (error as? PhoneRecipeEditingError)?.message ?? Self.explain(error)
            throw error
        }
    }

    func export() async {
        guard state.canExport, !bluetoothChoiceActive, !isResettingCamera, cameraError == nil, cameraResetError == nil,
              !isSubmitting, !recovering, !isSuspended, let recipe = state.selectedRecipe else { return }
        isSubmitting = true
        let sources = state.effectiveSources, engine = environment.exports
        let destination: ExportDestination = settings.updateOriginalInPhotos ? .updateOriginal : .separatePhoto
        // Revoke obsolete preparation before export reserves the shared scheduler/pool. An
        // already admitted native render remains independently owned by PreviewCoordinator.
        displayTask?.cancel(); displayIntent &+= 1; displayRequest = nil
        displayLoading = nil
        if isLoadingPreview { state.reduce(.previewInterrupted) }
        if !hasCurrentSourceDisplay { displayFile = nil; availableDisplay = nil }
        imageStatus = displayFile == nil ? "Image loading stopped. Select the recipe again to retry." : displayFailure
        await environment.preview.invalidate()
        let task = Task { try await engine.start(sources: sources, recipe: recipe, destination: destination) }
        submissionTask = task
        do {
            let id = try await task.value
            // A very short run can finish before start() returns. Never resurrect its active ID.
            if exportEvent?.jobID != id || exportEvent?.terminal != true { reduce(.activeJobChanged(id)); updateIdle() }
        } catch { message = Self.explain(error); restoreIdle() }
        submissionTask = nil; isSubmitting = false
        await recoverWhenIdle()
    }

    private func exportChanged(_ event: ExportEvent) async {
        guard event.sequence > recoverySequence else { return }
        applyProgress(event)
        if event.failures.contains(.unsupportedSource), let camera = state.photoFilterCamera,
           let job = try? await environment.catalog.job(id: event.jobID),
           camera == state.photoFilterCamera {
            let imported = job.recipeSnapshot.cameraContext
            if camera.model == imported.model, camera.firmware == imported.firmware,
               camera.capability == imported.capability,
               camera.supportVersion == (try? RecipeCodecRegistry().supportVersion(for: imported)) {
                for item in job.items where item.state == .failed(.unsupportedSource) {
                    reduce(.photoFilterAssessed(item.source, camera: camera, result: .incompatible))
                }
            }
        }
        if event.terminal { await adoptVerifiedReplacements(); await refreshVersions(); await recoverWhenIdle() }
    }
    private func applyProgress(_ event: ExportEvent) {
        exportEvent = event
        if !jobOrder.contains(event.jobID) { jobOrder.append(event.jobID) }
        if !event.terminal || event.summary.failed + event.summary.skipped + event.summary.unprocessed + event.summary.unresolved > 0 {
            unfinishedEvents[event.jobID] = event
        } else {
            unfinishedEvents[event.jobID] = nil
            jobOrder.removeAll { $0 == event.jobID }
        }
        reduce(.activeJobChanged(event.terminal ? nil : event.jobID))
        updateIdle()
    }

    func cancelExport(jobID: UUID? = nil) async {
        guard let id = jobID ?? exportEvent?.jobID ?? state.activeJobID else { return }
        await environment.exports.cancel(jobID: id)
    }
    func resumeExport(jobID: UUID? = nil, retry: Bool = false) async {
        let target = jobID.flatMap { unfinishedEvents[$0] } ?? exportEvent
        guard !isSuspended, !isResettingCamera, !state.wirelessRestrictsUSB, !bluetoothChoiceActive,
              cameraError == nil, cameraResetError == nil, !isSubmitting, !recovering, state.activeJobID == nil,
              case .ready = state.cameraState, let event = target, event.terminal,
              event.summary.unresolved == event.summary.replacementCleanup else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            if retry { try await environment.exports.retry(jobID: event.jobID) }
            else { try await environment.exports.resume(jobID: event.jobID) }
            if unfinishedEvents[event.jobID] == event || exportEvent == event { reduce(.activeJobChanged(event.jobID)); updateIdle() }
        } catch { message = Self.explain(error); restoreIdle() }
    }
    func reconcile() async { recoveryNeeded = true; await recoverWhenIdle() }
    var canFinishReplacements: Bool {
        foreground && !isSuspended && !isResettingCamera && !isSubmitting && !recovering && state.activeJobID == nil
    }
    func finishReplacement(jobID: UUID) async {
        let target = unfinishedEvents[jobID] ?? (exportEvent?.jobID == jobID ? exportEvent : nil)
        guard canFinishReplacements, let target, target.terminal, target.summary.replacementCleanup > 0 else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await environment.exports.finishReplacements(jobID: jobID)
            if exportEvent?.jobID != jobID || exportEvent?.terminal != true || exportEvent?.sequence == target.sequence {
                reduce(.activeJobChanged(jobID)); updateIdle()
            }
        } catch { message = Self.explain(error); restoreIdle() }
    }
    private func recoverWhenIdle() async {
        if !recoveryNeeded { recoveryNeeded = exportEvent == nil }
        guard recoveryNeeded, !recovering, !isSubmitting, state.activeJobID == nil else { return }
        recovering = true
        repeat {
            recoveryNeeded = false
            do {
                let snapshot = try await environment.exports.recover()
                recoverySequence = snapshot.sequence
                // Include recovered jobs which became saved as well as still-pending jobs, so
                // dropped terminal events cannot leave stale outcomes. Existing session retry
                // summaries outside the durable unfinished set remain actionable.
                for event in snapshot.jobs { applyProgress(event) }
                reduce(.activeJobChanged(nil)); updateIdle()
                // The watermark suppresses terminal events, including their refresh side effect.
                // Install every job first, then coalesce one refresh without blocking recovery.
                requestVersionRefresh()
            }
            catch { message = Self.explain(error) }
        } while recoveryNeeded && !isSubmitting && state.activeJobID == nil
        recovering = false
    }

    func sceneChanged(_ phase: ScenePhase) async {
        sceneRevision &+= 1
        let wirelessTransition = forwardWirelessActivity(phase)
        if phase == .inactive {
            foreground = false; cancelPhotoFilterChecks(); stopAutomaticConnection(); updateIdle()
            await wirelessTransition?.value
            return
        }
        let revision = sceneRevision
        if phase == .background {
            recipeLifecycleRevision &+= 1
            cameraResetRevision &+= 1
            cameraEventGeneration &+= 1; contextTask?.cancel()
            isResettingCamera = false; cameraResetCallActive = false
            cameraResetReadyAdopted = false; cameraResetAwaitingTerminal = false
            cameraResetDeferredDisconnect = false
            awaitingImportTerminal = false
            cameraError = nil; cameraResetError = nil
            reduce(.cameraResetChanged(false))
            state.reduce(.previewInterrupted)
            foreground = false; isSuspended = true; restoreIdle()
            cancelPhotoFilterChecks()
            stopAutomaticConnection()
            displayIntent &+= 1
            displayTask?.cancel(); displayRequest = nil
            displayLoading = !hasCurrentSourceDisplay && imageLoading != nil ? .loading : nil
        }
        let preceding = sceneTask
        let task = Task { [weak self] in
            await preceding?.value
            guard let self else { return }
            if phase == .background {
                await self.environment.preview.invalidate()
                await self.environment.exports.suspend()
                // Submission admission may be awaiting validation/persistence. Await its REAL ID.
                let submitted = try? await self.submissionTask?.value
                if let id = self.state.activeJobID ?? submitted { await self.environment.exports.pause(jobID: id) }
                await self.environment.camera.disconnect()
                await wirelessTransition?.value
                self.reduce(.activeJobChanged(nil))
                self.reduce(.cameraChanged(.disconnected, context: nil))
            } else if phase == .active {
                await wirelessTransition?.value
                guard self.sceneRevision == revision else { return }
                let wasSuspended = self.isSuspended
                self.foreground = true
                self.cameraAuthorizationDenied = false
                if wasSuspended {
                    await self.reloadLibrary()
                    self.recoveryNeeded = true; await self.recoverWhenIdle()
                    guard self.sceneRevision == revision else { return }
                    await self.environment.exports.allowForegroundWork()
                    guard self.sceneRevision == revision else { return }
                    self.isSuspended = false
                    self.requestDisplay(nil)
                }
                self.startAutomaticConnection()
                self.refreshPhotoFilterWorker()
                self.updateIdle()
            }
        }
        sceneTask = task
        await task.value
    }

    private func updateIdle() {
        if !isSuspended && state.activeJobID != nil {
            if previousIdle == nil { previousIdle = environment.platform.idleTimerDisabled }
            environment.platform.idleTimerDisabled = true
        } else { restoreIdle() }
    }
    private func restoreIdle() {
        if let previousIdle { environment.platform.idleTimerDisabled = previousIdle; self.previousIdle = nil }
    }
    func managePhotos() { environment.platform.managePhotos() }
    func openSettings() { environment.platform.openSettings() }
    private func refreshVersions() async { await requestVersionRefresh().value }

    @discardableResult private func requestVersionRefresh() -> Task<Void, Never> {
        versionRefreshGeneration &+= 1
        let source = state.viewedSourceID
        if let task = versionRefreshTask, versionRefreshSource == source { return task }
        versionRefreshTask?.cancel()
        versionRefreshSource = source
        versionRefreshWorker &+= 1
        let worker = versionRefreshWorker
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.versionRefreshWorker == worker else { return }
                let generation = self.versionRefreshGeneration
                await self.readVersions(generation: generation)
                guard self.versionRefreshWorker == worker else { return }
                if self.versionRefreshGeneration == generation {
                    self.versionRefreshTask = nil
                    return
                }
                // Same-source requests during an await are one follow-up pass. The stale pass
                // cannot publish; a different source gets its own current worker immediately.
            }
        }
        versionRefreshTask = task
        return task
    }

    private func readVersions(generation: UInt64) async {
        guard let id = state.viewedSourceID else { savedVersions = []; return }
        let revision = state.viewedSourceRevision, scope = libraryGeneration
        func isCurrent() -> Bool {
            !Task.isCancelled && versionRefreshGeneration == generation && state.viewedSourceID == id
                && state.viewedSourceRevision == revision && libraryGeneration == scope
        }
        do {
            let records = try await environment.catalog.versions(sourceID: id)
            guard isCurrent() else { return }
            var editedAvailability: [UUID: AssetAvailability] = [:]
            for record in records {
                let availability: AssetAvailability
                do {
                    availability = try await environment.resolver.availability(of: record)
                } catch ResourceError.inaccessibleAsset { availability = .inaccessible }
                catch ResourceError.authorization { availability = .inaccessible }
                catch where record.destination == .updateOriginal { availability = .inaccessible }
                catch { continue } // A transient lookup failure is not proof of deletion.
                guard isCurrent() else { return }
                if record.destination == .updateOriginal {
                    // Several operations share an asset. Its latest marker determines each
                    // record's availability; the asset-wide catalog setter cannot express it.
                    editedAvailability[record.id] = availability
                    continue
                }
                if availability != record.availability {
                    try await environment.catalog.setAvailability(assetID: record.outputAssetID, availability: availability)
                    guard isCurrent() else { return }
                }
            }
            let versions = try await environment.catalog.versions(sourceID: id).map { record in
                var current = record
                if record.destination == .updateOriginal { current.availability = editedAvailability[record.id] ?? .inaccessible }
                return current
            }
            guard isCurrent() else { return }
            savedVersions = versions.filter { $0.destination == .separatePhoto || $0.availability == .available }
            if case .saved(let selected) = state.displayedVersion,
               let version = versions.first(where: { $0.id == selected }), version.availability != .available {
                if version.destination == .updateOriginal {
                    send(.versionSelected(sources.first(where: { $0.id == id })?.originalResources.jpeg == nil ? .raw : .cameraJPEG))
                    return
                }
                displayIntent &+= 1
                displayTask?.cancel(); displayRequest = nil; availableDisplay = nil
                displayFile = nil
                displayLoading = nil
                imageStatus = "This saved image is unavailable. Manage Photos access to include it."
                await environment.preview.invalidate()
            }
        } catch { if isCurrent() { message = Self.explain(error) } }
    }
    private static func sorted(_ values: [PhotoSource]) -> [PhotoSource] {
        values.sorted { ($0.captureDate ?? .distantPast) == ($1.captureDate ?? .distantPast) ? $0.id < $1.id : ($0.captureDate ?? .distantPast) > ($1.captureDate ?? .distantPast) }
    }
    static func explain(_ error: Error) -> String {
        switch error {
        case ResourceError.authorization, PhotoLibraryWriteError.authorization: "Allow Photos access in Settings to view originals and save exports."
        case ResourceError.inaccessibleAsset: "This photo is no longer accessible. Manage Photos access to include it."
        case ResourceError.insufficientStorage, CameraServiceError.storage, RenderCacheError.storage: "There is not enough storage to prepare this photo. Free some space and retry."
        case ResourceError.retrievalFailed: "The original could not be downloaded. Check your connection and iCloud Photos, then retry."
        case ResourceError.incompatibleCamera, CameraServiceError.unsupportedSource: "This RAW is not supported by the connected camera."
        case CameraServiceError.unsupportedContext: "Use a supported Fujifilm camera and firmware in USB RAW CONV./BACKUP RESTORE mode."
        case CameraServiceError.uncertainOperation, CameraServiceError.closeUnconfirmed, WirelessFailure.usbCloseUnconfirmed:
            "The camera operation could not be confirmed. Reconnect to reconcile before starting more work."
        case WirelessFailure.cameraBusy: "The camera is in use. Finish the current connection before trying again."
        case CameraServiceError.recipeImportFailed: "Recipe import failed. The previous collection is retained. Reconnect before retrying."
        case is CameraServiceError: "Camera connection interrupted. Check USB RAW CONV./BACKUP RESTORE mode and a USB data cable, then reconnect."
        case is CatalogError: "The local catalog could not be updated. Existing exports and recovery records are retained."
        default: "The operation could not finish. Your existing versions are retained. Try again when the source and camera are available."
        }
    }
    private func previewMessage(_ failure: PreviewFailure) -> String {
        if case .camera = failure, let cameraError { return cameraError }
        return switch failure {
        case .rawDisplayUnavailable: "RAW display is unavailable. Camera conversion is still available."
        case .source(let error): Self.explain(error)
        case .camera(let error): Self.explain(error)
        case .cache: "The temporary image is unavailable. Select the recipe to regenerate it."
        case .cancelled: "Image loading stopped. Select a version to retry."
        case .unavailable: "This image is unavailable. Manage Photos access or select another version."
        }
    }
    private static func loadingMessage(_ state: PreviewState) -> String {
        if case .progress(let value) = state, value.isFinite {
            return "Downloading image… \(Int((max(0, min(1, value)) * 100).rounded()))%"
        }
        return "Loading image…"
    }
}

extension AppModel {
    private func observeWireless() async {
        let services = environment.wireless
        let states = await services.connection.states()
        let events = await services.importer.events()
        streams.append(Task { [weak self] in
            for await snapshot in states {
                guard !Task.isCancelled else { break }
                #if DEBUG
                if snapshot.bluetooth == .discovering, self?.validationDropDiscoveryUpdates == true { continue }
                #endif
                self?.adoptWirelessState(snapshot)
            }
        })
        streams.append(Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { break }
                self?.adoptImportEvent(event)
            }
        })
        cameraBrowser.onSessionInvalidated = { [weak self] failure in
            guard let self, let intent = self.browserIntent else { return }
            self.retireWirelessTransfer(intent, failure: failure)
        }
        await services.connection.setActivity(wirelessActivity)
        adoptWirelessState(await services.connection.currentState())
    }

    private func adoptWirelessState(_ snapshot: WirelessConnectionState) {
        guard snapshot.sequence >= wirelessState.sequence else { return }
        let previous = wirelessState
        wirelessState = snapshot
        if snapshot.bluetooth != previous.bluetooth,
           (previous.bluetooth == .pairing || previous.bluetooth == .discovering),
           snapshot.bluetooth != .pairing, snapshot.bluetooth != .discovering {
            finishBluetoothChoice(bluetoothChoice?.id)
        }
        refreshUSBRestriction()
        if snapshot.selectedCameraID != nil || state.wirelessRestrictsUSB { stopAutomaticConnection() }
        else if snapshot.activity == .active { startAutomaticConnection() }

        if snapshot.wifi != .ready || snapshot.activity == .background
            || previous.connectionGeneration != snapshot.connectionGeneration {
            if browserIntent != nil || browserLoadTask != nil {
                let loanID = browserLoanID
                clearCameraBrowser()
                if let loanID, wirelessActivity != .background, !isDisconnectingWireless {
                    let importer = environment.wireless.importer
                    Task { await importer.retireLoan(loanID, reason: .connectionLost) }
                }
            }
        }
        if snapshot.wifi == .ready, snapshot.activity != .background,
           wirelessActivity != .background, !isDisconnectingWireless, retiringBrowserIntent == nil,
           browserIntent == nil, browserLoadTask == nil {
            loadCurrentCameraBrowser()
        }
    }

    private func refreshUSBRestriction() {
        let restricted = wifiCommandActive || isDisconnectingWireless || wirelessState.restrictsUSB
        if state.wirelessRestrictsUSB != restricted { reduce(.wirelessOwnershipChanged(restricted)) }
    }

    private func loadCurrentCameraBrowser() {
        let connection = environment.wireless.connection
        let browser = cameraBrowser
        let epoch = wirelessEpoch
        browserLoadTask = Task { [weak self] in
            guard let transfer = try? await connection.admittedTransfer(),
                  !Task.isCancelled, self?.wirelessEpoch == epoch,
                  self?.wirelessState.connectionGeneration == transfer.intent.connectionGeneration else { return }
            self?.browserIntent = transfer.intent
            self?.browserLoanID = transfer.loanID
            await browser.load(session: transfer.session)
        }
    }

    private func clearCameraBrowser() {
        browserLoadTask?.cancel()
        browserLoadTask = nil
        browserIntent = nil
        browserLoanID = nil
        browserBadgeTask?.cancel()
        browserBadgeTask = nil
        browserFingerprints.removeAll()
        cameraBrowser.cancel()
    }

    private func retireWirelessTransfer(_ intent: WirelessConnectionIntent, failure: WirelessFailure?) {
        guard retiringBrowserIntent != intent else { return }
        let loanID = browserIntent == intent ? browserLoanID : nil
        if browserIntent == intent {
            retiringBrowserIntent = intent
            clearCameraBrowser()
        }
        let services = environment.wireless
        Task { [weak self] in
            async let close: Void = services.connection.retireTransfer(intent, failure: failure)
            if let loanID { await services.importer.retireLoan(loanID, reason: .connectionLost) }
            await close
            let snapshot = await services.connection.currentState()
            if self?.retiringBrowserIntent == intent { self?.retiringBrowserIntent = nil }
            self?.adoptWirelessState(snapshot)
        }
    }

    private func forwardWirelessActivity(_ phase: ScenePhase) -> Task<Void, Never>? {
        let activity: WirelessActivity = switch phase {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        @unknown default: .inactive
        }
        let previous = wirelessActivity
        wirelessActivity = activity
        guard started, wirelessAvailable else { return nil }
        let connection = environment.wireless.connection
        if activity == .background {
            if previous == .background, let wirelessBackgroundTask { return wirelessBackgroundTask }
            wirelessEpoch &+= 1
            if bluetoothChoice?.isCancelling != true { bluetoothChoice = nil }
            let precedingCleanup = wirelessBackgroundTask
            let loading = browserLoadTask
            let loanID = browserLoanID
            clearCameraBrowser()
            let pending = importCommand
            pending?.task.cancel()
            let jobIDs = importJobsToPause(including: pending?.jobID)
            let services = environment.wireless
            let cleanup = Task { [weak self] in
                async let close: Void = connection.setActivity(.background)
                let retiredJob = if let loanID { await services.importer.retireLoan(loanID, reason: .backgrounded) } else { nil as UUID? }
                for jobID in jobIDs where jobID != retiredJob {
                    await services.importer.pause(jobID: jobID, reason: .backgrounded)
                }
                await pending?.task.value
                await loading?.value
                await services.browser.suspendThumbnails()
                await close
                // The coordinator may already have recorded Background while a previous
                // teardown is pending. Its duplicate phase call does not own that teardown.
                await precedingCleanup?.value
                self?.adoptWirelessState(await connection.currentState())
            }
            wirelessBackgroundTask = cleanup
            return cleanup
        }
        let cleanup = wirelessBackgroundTask
        let epoch = wirelessEpoch
        return Task { [weak self] in
            await cleanup?.value
            guard let self, self.wirelessEpoch == epoch, self.wirelessActivity == activity else { return }
            self.wirelessBackgroundTask = nil
            await connection.setActivity(activity)
            self.adoptWirelessState(await connection.currentState())
            if activity == .active, self.wirelessEpoch == epoch, self.wirelessActivity == .active {
                await self.reconcileImports()
            }
        }
    }

    private func importJobsToPause(including pending: UUID?) -> Set<UUID> {
        var jobs = Set(importEvents.compactMap { event in
            event.isRunning || (!event.needsSession && event.captureIndex != nil) ? event.jobID : nil
        })
        if let pending { jobs.insert(pending) }
        return jobs
    }

    private func prepareBluetoothChoice() async -> UUID? {
        guard !Task.isCancelled, wirelessAvailable, wirelessActivity == .active, !isSuspended, !state.wirelessRestrictsUSB,
              !bluetoothChoiceActive, state.activeJobID == nil, !isSubmitting, !isRefreshing, !isResettingCamera else { return nil }
        let choice = BluetoothChoice()
        bluetoothChoice = choice
        stopAutomaticConnection()
        wirelessActionError = nil
        let epoch = wirelessEpoch
        do {
            try await environment.camera.disconnectConfirmed()
            guard epoch == wirelessEpoch, wirelessActivity != .background, !Task.isCancelled,
                  bluetoothChoice?.id == choice.id, bluetoothChoice?.isCancelling == false else {
                finishBluetoothChoice(choice.id)
                return nil
            }
            return choice.id
        } catch {
            if !Task.isCancelled, bluetoothChoice?.id == choice.id { wirelessActionError = Self.explain(error) }
            finishBluetoothChoice(choice.id)
            return nil
        }
    }

    private func finishBluetoothChoice(_ id: UUID?) {
        guard let id, bluetoothChoice?.id == id, bluetoothChoice?.isCancelling == false else { return }
        bluetoothChoice = nil
        if wirelessActivity == .active { startAutomaticConnection() }
    }

    func discoverWirelessCameras() async {
        guard let choiceID = await prepareBluetoothChoice() else { return }
        let connection = environment.wireless.connection
        await connection.startDiscovery()
        #if DEBUG
        await validationDiscoveryStateRead?.wait()
        #endif
        adoptWirelessState(await connection.currentState())
        if wirelessState.bluetooth != .discovering && wirelessState.bluetooth != .pairing {
            finishBluetoothChoice(choiceID)
        }
    }

    func pairWirelessCamera(_ camera: DiscoveredCamera) async {
        let choiceID = bluetoothChoice?.id
        let connection = environment.wireless.connection
        await connection.pair(camera)
        adoptWirelessState(await connection.currentState())
        if wirelessState.bluetooth != .pairing && wirelessState.bluetooth != .discovering {
            finishBluetoothChoice(choiceID)
        }
    }

    func selectWirelessCamera(_ id: WirelessCameraID) async {
        guard let choiceID = await prepareBluetoothChoice() else { return }
        defer { finishBluetoothChoice(choiceID) }
        do { try await environment.wireless.connection.select(id) }
        catch { if !Task.isCancelled { wirelessActionError = Self.explain(error) } }
        adoptWirelessState(await environment.wireless.connection.currentState())
    }

    func forgetWirelessCamera(_ id: WirelessCameraID) async {
        guard wirelessAvailable, wirelessActivity == .active, !state.wirelessRestrictsUSB else { return }
        let choiceID = bluetoothChoice?.id
        do { try await environment.wireless.connection.forget(id); wirelessActionError = nil }
        catch { wirelessActionError = Self.explain(error) }
        adoptWirelessState(await environment.wireless.connection.currentState())
        finishBluetoothChoice(choiceID)
    }

    func retryCameraBluetooth() async {
        guard let choiceID = await prepareBluetoothChoice() else { return }
        defer { finishBluetoothChoice(choiceID) }
        await environment.wireless.connection.retryBluetooth()
        adoptWirelessState(await environment.wireless.connection.currentState())
    }

    func cancelWirelessConnection(draining pending: Task<Void, Never>?) async {
        let choiceID = bluetoothChoice?.id
        bluetoothChoice?.isCancelling = true
        let connection = environment.wireless.connection
        await connection.cancelConnection(preservingReadyTransfer: true)
        await pending?.value
        adoptWirelessState(await connection.currentState())
        if let choiceID, bluetoothChoice?.id == choiceID {
            bluetoothChoice?.isCancelling = false
            finishBluetoothChoice(choiceID)
        }
    }

    func connectCameraWiFi() async {
        await runWiFiCommand { await $0.connectWiFi() }
    }

    func setUpCameraAutoSave() async {
        await runWiFiCommand { await $0.setUpAutoSave() }
    }

    func waitForCameraAutoSave() async {
        await runWiFiCommand { await $0.waitForAutoSave() }
    }

    func checkCameraAutoSaveAvailability() async throws {
        try await environment.wireless.connection.checkAutoSaveAvailability()
    }

    private func runWiFiCommand(_ operation: (WirelessConnectionCoordinator) async -> Void) async {
        guard !Task.isCancelled, wirelessAvailable, wirelessActivity == .active, !isSuspended, wirelessState.wifi == .idle,
              !wifiCommandActive, importCommand == nil, !importEvents.contains(where: \.isRunning) else { return }
        wirelessActionError = nil
        wifiCommandActive = true
        refreshUSBRestriction()
        stopAutomaticConnection()
        let connection = environment.wireless.connection
        await operation(connection)
        wifiCommandActive = false
        adoptWirelessState(await connection.currentState())
        await browserLoadTask?.value
    }

    func disconnectCameraWiFi() async {
        guard wirelessAvailable, !isDisconnectingWireless else { return }
        isDisconnectingWireless = true
        refreshUSBRestriction()
        let services = environment.wireless
        let loading = browserLoadTask
        let loanID = browserLoanID
        clearCameraBrowser()
        let pending = importCommand
        pending?.task.cancel()
        let jobIDs = importJobsToPause(including: pending?.jobID)
        async let close: Void = services.connection.disconnectWiFi()
        let retiredJob = if let loanID { await services.importer.retireLoan(loanID, reason: .connectionLost) } else { nil as UUID? }
        for jobID in jobIDs where jobID != retiredJob && wirelessActivity != .background {
            await services.importer.pause(jobID: jobID, reason: .connectionLost)
        }
        await pending?.task.value
        await loading?.value
        await cameraBrowser.suspendThumbnails()
        await close
        isDisconnectingWireless = false
        adoptWirelessState(await services.connection.currentState())
    }

    func importSelectedCaptures() async { await runImportCommand(.start) }
    func resumeImport(jobID: UUID) async { await runImportCommand(.resume(jobID)) }
    func retryImportCapture(jobID: UUID) async { await runImportCommand(.retry(jobID)) }
    func skipImportCapture(jobID: UUID) async { await runImportCommand(.skip(jobID)) }

    func pauseImport(jobID: UUID) async {
        await environment.wireless.importer.pause(jobID: jobID)
    }

    func cancelImport(jobID: UUID) async {
        await environment.wireless.importer.cancelRemaining(jobID: jobID)
    }

    func discardImport(jobID: UUID) async {
        guard wirelessAvailable, wirelessActivity == .active else { return }
        do { try await environment.wireless.importer.discardRemaining(jobID: jobID); importActionError = nil }
        catch { importActionError = Self.explainImport(error) }
    }

    func manageImportPhotos() async {
        guard wirelessAvailable, wirelessActivity == .active else { return }
        let access = await environment.wireless.requestPhotosAccess()
        guard wirelessActivity != .background else { return }
        if access == .limited { environment.platform.managePhotos() }
        importActionError = access == .full || access == .limited ? nil : Self.explainImport(PhotoImportFailure.authorization)
        await reconcileImports()
    }

    private enum ImportCommand {
        case start, resume(UUID), retry(UUID), skip(UUID)

        var jobID: UUID? {
            switch self {
            case .start: nil
            case .resume(let id), .retry(let id), .skip(let id): id
            }
        }
        var requiresSession: Bool {
            switch self {
            case .start, .resume: true
            case .retry, .skip: false
            }
        }
    }

    private func runImportCommand(_ operation: ImportCommand) async {
        guard wirelessAvailable, wirelessActivity == .active, !isSuspended, !isDisconnectingWireless, importCommand == nil,
              !importEvents.contains(where: \.isRunning) else { return }
        importActionError = nil
        isPreparingImport = true
        let epoch = wirelessEpoch
        let task = Task { [weak self] in await self?.performImportCommand(operation, epoch: epoch) ?? () }
        importCommand = (operation.jobID, task)
        await task.value
        importCommand = nil
        isPreparingImport = false
        releaseBrowserIfIdle()
        if importReconcilePending, wirelessActivity != .background { await reconcileImports() }
    }

    private func performImportCommand(_ operation: ImportCommand, epoch: UInt64) async {
        let services = environment.wireless
        do {
            await importReconciliation?.value
            try checkImportEpoch(epoch)
            let previous = if let jobID = operation.jobID { await services.importer.latestRunEvent(jobID: jobID) } else { nil as ImportEvent? }
            let transfer = try? await services.connection.admittedTransfer()
            if operation.requiresSession && transfer == nil { throw CameraImportError.sessionRequired }
            if let transfer {
                // The first usable native inventory batch may precede the full browser index.
                // Finish browser inventory, then fence queued previews before freezing routes.
                await browserLoadTask?.value
                await cameraBrowser.suspendThumbnails()
                try checkImportEpoch(epoch)
                guard browserIntent == transfer.intent, !cameraBrowser.isLoading, !cameraBrowser.requiresFreshSession,
                      try await services.connection.admittedTransfer().intent == transfer.intent else {
                    throw CameraBrowserSelectionError.inventoryNotReady
                }
            }
            try checkImportEpoch(epoch)
            let jobID: UUID
            let intent: WirelessConnectionIntent?
            switch operation {
            case .start:
                guard let transfer else { throw CameraImportError.sessionRequired }
                let selections = try cameraBrowser.selectionForImport()
                guard !selections.isEmpty else { return }
                let access = await services.requestPhotosAccess()
                try checkImportEpoch(epoch)
                guard access == .full || access == .limited else { throw PhotoImportFailure.authorization }
                guard try await services.connection.admittedTransfer().intent == transfer.intent else {
                    throw CameraImportError.sessionRequired
                }
                let cameraName = wirelessState.savedCameras.first { $0.id == transfer.intent.cameraID }?.displayName
                jobID = try await services.importer.start(selections, session: transfer.session, loanID: transfer.loanID,
                                                          cameraDisplayName: cameraName)
                intent = transfer.intent
            case .resume(let id):
                guard let transfer else { throw CameraImportError.sessionRequired }
                jobID = id
                try await services.importer.resume(jobID: id, session: transfer.session, loanID: transfer.loanID)
                intent = transfer.intent
            case .retry(let id), .skip(let id):
                jobID = id
                let retained = importBinding[id]?.intent
                let latest = await services.importer.latestEvent(jobID: id)
                intent = latest?.needsSession == false && retained == transfer?.intent ? retained : nil
                let allowedLoanID = intent == nil ? nil : transfer?.loanID
                try checkImportEpoch(epoch)
                switch operation {
                case .retry: try await services.importer.retryCapture(jobID: id, usingLoanID: allowedLoanID)
                default: try await services.importer.skipCapture(jobID: id, usingLoanID: allowedLoanID)
                }
            }
            if let event = await services.importer.latestRunEvent(jobID: jobID),
               let runID = event.runID, runID != previous?.runID {
                if wirelessEpoch == epoch && !Task.isCancelled {
                    let hasNativeEvidence = operation.requiresSession || !event.needsSession
                        || event.invalidatedSession || event.routeEvidence != nil
                    importBinding[jobID] = .init(runID: runID, intent: hasNativeEvidence ? intent : nil)
                    adoptImportEvent(event)
                } else {
                    await services.importer.pause(jobID: jobID, reason: wirelessActivity == .background ? .backgrounded : .connectionLost)
                }
            }
        } catch is CancellationError { }
        catch {
            if wirelessEpoch == epoch && !Task.isCancelled { importActionError = Self.explainImport(error) }
        }
    }

    private func checkImportEpoch(_ epoch: UInt64) throws {
        try Task.checkCancellation()
        guard wirelessEpoch == epoch, wirelessActivity != .background else { throw CancellationError() }
    }

    private func releaseBrowserIfIdle() {
        guard importCommand == nil, !importEvents.contains(where: \.isRunning) else { return }
        cameraBrowser.deselectVerifiedCaptures()
        if let intent = browserIntent, importEvents.contains(where: { event in
            guard let jobID = event.jobID else { return false }
            return !event.needsSession && importBinding[jobID]?.intent == intent
        }) { return }
        cameraBrowser.resumeThumbnails()
    }

    private func adoptImportEvent(_ event: ImportEvent) {
        guard let jobID = event.jobID else {
            if importJournalSequence < event.sequence {
                importJournalSequence = event.sequence
                importJournalIssue = event
            }
            return
        }
        if (importEventsByJob[jobID]?.sequence ?? 0) < event.sequence {
            importEventsByJob[jobID] = event
            if !event.receipts.isEmpty, receiptTasks[jobID] == nil {
                receiptTasks[jobID] = Task { [weak self] in await self?.mergeJobReceipts(jobID) }
            }
        }
        if let runID = event.runID, var binding = importBinding[jobID], binding.runID == runID,
           binding.lastEvent < event.sequence {
            binding.lastEvent = event.sequence
            importBinding[jobID] = binding
            if let intent = binding.intent {
                if event.invalidatedSession {
                    retireWirelessTransfer(intent, failure: event.wirelessFailure ?? .connectionLost)
                } else if !event.isRunning, let evidence = event.routeEvidence, evidence.runID == runID,
                          browserIntent == intent, cameraBrowser.inventorySessionID == evidence.sessionID {
                    browserFingerprints.merge(evidence.fingerprints, uniquingKeysWith: { _, observed in observed })
                    refreshBrowserBadges()
                }
            }
        }
        releaseBrowserIfIdle()
    }

    private func reconcileImports(afterPhotoVisibilityChange: Bool = false) async {
        guard importCommand == nil else { importReconcilePending = true; return }
        if let importReconciliation {
            // The current pass may already have read this asset under the earlier grant.
            if afterPhotoVisibilityChange { importReconcilePending = true }
            else { await importReconciliation.value }
            return
        }
        repeat {
            importReconcilePending = false
            let task = Task { [weak self] in await self?.reconcileImportSnapshot() ?? () }
            importReconciliation = task
            await task.value
            importReconciliation = nil
        } while importReconcilePending && importCommand == nil && wirelessActivity != .background
    }

    private func reconcileImportSnapshot() async {
        let importer = environment.wireless.importer
        let previouslyUnfinished = Set(importRecoveryEvents.compactMap(\.jobID))
        await importer.reconcile()
        let journal = await importer.recoveryIssue()
        if importJournalSequence <= journal.sequence {
            importJournalSequence = journal.sequence
            importJournalIssue = journal.event
        }
        let recovery = await importer.recoverySnapshot()
        for event in recovery { adoptImportEvent(event) }
        for id in previouslyUnfinished.subtracting(recovery.compactMap(\.jobID)) {
            if let latest = await importer.latestEvent(jobID: id) { adoptImportEvent(latest) }
        }
        refreshBrowserBadges()
    }

    private func refreshBrowserBadges() {
        guard !browserFingerprints.isEmpty, let intent = browserIntent,
              let sessionID = cameraBrowser.inventorySessionID else { return }
        browserBadgeTask?.cancel()
        let browser = cameraBrowser, recovery = environment.wireless.importer.recovery
        let fingerprints = browserFingerprints
        browserBadgeTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            try? await browser.refreshImportReceipts(using: recovery, originalFingerprints: fingerprints)
            guard !Task.isCancelled, let self, self.browserIntent == intent,
                  browser.inventorySessionID == sessionID else { return }
            self.releaseBrowserIfIdle()
        }
    }

    private struct ImportPhotoVisibility {
        struct Candidate {
            let rawFilename: String
            let creationDate: Date

            func matches(_ source: PhotoSource) -> Bool {
                guard source.originalResources.raf.originalFilename.caseInsensitiveCompare(rawFilename) == .orderedSame else { return false }
                return source.captureDate.map { abs($0.timeIntervalSince(creationDate)) <= 1 } ?? true
            }
        }

        var journalReadable = true
        var verified: Set<SourceID> = []
        var pending: Set<SourceID> = []
        var unidentified: [Candidate] = []
        var jobsByAssetID: [SourceID: Set<UUID>] = [:]
        var needsEstablishedIDs: Bool { !journalReadable || !unidentified.isEmpty }

        func allows(_ source: PhotoSource, establishedIDs: Set<SourceID>) -> Bool {
            if !journalReadable { return establishedIDs.contains(source.id) }
            if verified.contains(source.id) { return true }
            if pending.contains(source.id) { return false }
            if establishedIDs.contains(source.id) { return true }
            return !unidentified.contains { $0.matches(source) }
        }
    }

    private enum ImportInsertion { case verified, pendingVerification }

    private func currentImportInsertion(_ ids: Set<SourceID>) async -> ImportInsertion? {
        let visibility = await importPhotoVisibility(indexInsertionOwners: true)
        let importer = environment.wireless.importer
        for id in ids {
            guard let jobs = visibility.jobsByAssetID[id] else { return nil }
            var owned = false
            for jobID in jobs {
                if importBinding[jobID] != nil || importEventsByJob[jobID]?.isRunning == true {
                    owned = true
                    break
                }
                // PhotoKit can notify before start() has returned its job and run IDs.
                if importCommand != nil, await importer.latestRunEvent(jobID: jobID) != nil {
                    owned = true
                    break
                }
            }
            if !owned { return nil }
        }
        return visibility.pending.isDisjoint(with: ids) ? .verified : .pendingVerification
    }

    private func importPhotoVisibility(indexInsertionOwners: Bool = false) async -> ImportPhotoVisibility {
        guard wirelessAvailable else { return .init() }
        do {
            let jobs = try await environment.wireless.journal.loadJobs()
            var visibility = ImportPhotoVisibility()
            for job in jobs {
                for capture in job.captures {
                    if let receipt = capture.receipt {
                        visibility.verified.insert(receipt.assetID)
                        if indexInsertionOwners { visibility.jobsByAssetID[receipt.assetID, default: []].insert(job.id) }
                    }
                    if capture.stage.mayHaveSubmitted {
                        if let id = capture.placeholderAssetID {
                            visibility.pending.insert(id)
                            if indexInsertionOwners { visibility.jobsByAssetID[id, default: []].insert(job.id) }
                        } else if let raw = capture.originals.first(where: { $0.role == .raf }) {
                            let metadata = OriginalImportValidator.photoMetadata(
                                capture.selection, originals: capture.originals, importDate: job.importDate)
                            visibility.unidentified.append(.init(rawFilename: raw.originalFilename, creationDate: metadata.creationDate))
                        }
                    }
                }
            }
            return visibility
        } catch {
            importActionError = "The import journal could not be read. Reopen Fuji Studio or check available storage."
            return .init(journalReadable: false)
        }
    }

    private func mergeJobReceipts(_ jobID: UUID) async {
        defer { receiptTasks[jobID] = nil }
        var sequence: UInt64 = 0
        while let event = importEventsByJob[jobID], event.sequence > sequence, !Task.isCancelled {
            sequence = event.sequence
            let known = Set(sources.map(\.id))
            let receipts = event.receipts.filter { !known.contains($0.assetID) }
            _ = await mergeVerifiedPhotos(receipts)
        }
    }

    @discardableResult
    private func mergeVerifiedPhotos(_ receipts: [ImportReceipt]) async -> [PhotoSource] {
        var added: [SourceID: PhotoSource] = [:]
        let generation = libraryGeneration
        for id in Set(receipts.map(\.assetID)) {
            do { added[id] = knownCompatibility(try await environment.reader.source(id: id)) }
            catch ResourceError.inaccessibleAsset { continue }
            catch ResourceError.authorization { continue }
            catch { importActionError = Self.explain(error) }
        }
        guard !added.isEmpty, !Task.isCancelled, generation == libraryGeneration,
              state.libraryAccess == .full || state.libraryAccess == .limited else { return [] }
        do { try await environment.catalog.upsertSources(Array(added.values)) }
        catch { importActionError = Self.explain(error); return [] }
        establishedSourceIDs.formUnion(added.keys)
        guard !Task.isCancelled, generation == libraryGeneration else { return [] }
        var merged = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        merged.merge(added, uniquingKeysWith: { _, new in new })
        sources = Self.sorted(Array(merged.values))
        importMergeRevision &+= 1
        for id in added.keys { recentImportMerges[id] = importMergeRevision }
        reduce(.libraryUpdated(sources: sources, access: state.libraryAccess))
        return Self.sorted(Array(added.values))
    }

    func viewImported(jobID: UUID) async {
        guard wirelessAvailable else { return }
        do {
            let job = try await environment.wireless.importer.recovery.load(jobID)
            let receipts = job.captures.compactMap(\.receipt)
            let imported = await mergeVerifiedPhotos(receipts)
            if let newest = imported.first {
                importActionError = nil
                reduce(.viewImported(ids: Set(imported.map(\.id)), newest: newest.id))
            } else if !receipts.isEmpty {
                importActionError = "Imported photos are unavailable. Check Photos access."
            }
        } catch { importActionError = Self.explainImport(error) }
    }

    private static func explainImport(_ error: Error) -> String {
        switch error {
        case PhotoImportFailure.authorization: "Allow read and write Photos access to import camera originals."
        case CameraImportError.sessionRequired: "Connect to camera Wi-Fi before resuming downloads."
        case CameraImportError.freshSelectionRequired, CameraBrowserSelectionError.captureChanged:
            "The selected card files changed. Select the originals again."
        case CameraBrowserSelectionError.inventoryNotReady: "Reconnect and wait for the camera card to finish loading."
        case CameraImportError.unresolvedSave: "Verify the previous Photos save before trying it again."
        case is ImportJournalError: "The import journal needs recovery. Retained originals are still on this device."
        default: Self.explain(error)
        }
    }
}
