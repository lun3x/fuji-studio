import Foundation

enum VersionID: Sendable, Hashable {
    case raw, cameraJPEG, saved(UUID), preview(RenderKey)
}

enum DrawerDetent: Sendable, Equatable { case collapsed, expanded }
enum RecipeRefreshState: Sendable, Equatable { case fresh, stale(String) }

struct WorkspacePreviewRequest: Sendable, Equatable {
    let generation: UInt64
    let sourceID: SourceID
    let sourceRevision: String
    let recipe: RecipeSnapshot
    let cameraContext: CameraExecutionContext
}

enum WorkspaceEffect: Sendable, Equatable {
    case requestPreview(WorkspacePreviewRequest)
    case scrollToVisible(sourceID: SourceID)
}

enum WorkspaceAction: Sendable {
    case sourceTapped(SourceID)
    case select, done
    /// Range sweep membership only; never changes viewed source or preview intent.
    case checkedSourcesReplaced(Set<SourceID>)
    case versionSelected(VersionID)
    case recipeSelected(slot: Int?)
    case recipesRefreshed([RecipeSnapshot])
    case recipeRefreshFailed(String)
    /// Complete accessible metadata index after removals or an authorization change.
    case libraryUpdated(sources: [PhotoSource], access: LibraryAccess)
    case cameraChanged(CameraState, context: CameraExecutionContext?)
    case activeJobChanged(UUID?)
    case drawerMoved(DrawerDetent)
    case previewInterrupted
    /// Publish the version matching a retained file without changing the requested recipe.
    case previewFallback(VersionID)
    case previewCompleted(request: WorkspacePreviewRequest, key: RenderKey)
}

enum WorkspaceExportDisabledReason: Sendable, Equatable {
    case noSources, noRecipe, activeJob, cameraNotReady, cameraContextUnavailable, recipeCameraMismatch
    case incompatibleSource(sourceID: SourceID, model: String)
    case unsupportedRecipe([RecipeRenderingIssue])

    var message: String {
        switch self {
        case .noSources: "Choose a photo to export."
        case .noRecipe: "Choose a camera recipe to export."
        case .activeJob: "Wait for the current export to finish."
        case .cameraNotReady: "Connect an X-T5 and wait for it to be ready."
        case .cameraContextUnavailable: "Verify the connected camera before exporting."
        case .recipeCameraMismatch: "Refresh recipes from the connected camera."
        case .incompatibleSource(_, let model): "This RAW was captured by \(model) and cannot be converted by the X-T5."
        case .unsupportedRecipe: "This recipe contains settings the current camera conversion profile cannot render."
        }
    }
}

struct WorkspaceState: Sendable {
    private(set) var viewedSourceID: SourceID?
    private(set) var displayedVersion: VersionID?
    private(set) var selectedRecipe: RecipeSnapshot?
    private(set) var isSelecting = false
    private(set) var checkedSourceIDs: Set<SourceID> = []
    private(set) var drawerDetent: DrawerDetent = .collapsed
    private(set) var recipes: [RecipeSnapshot] = []
    private(set) var recipeRefreshState: RecipeRefreshState = .fresh
    private(set) var currentCameraExecutionContext: CameraExecutionContext?
    private(set) var cameraState: CameraState = .disconnected
    private(set) var activeJobID: UUID?
    private(set) var libraryAccess: LibraryAccess
    private var sources: [SourceID: PhotoSource]
    private var displayGeneration: UInt64 = 0
    private var pendingPreview: WorkspacePreviewRequest?
    private var wantsRecipePreview = false
    private var previewSatisfied = false
    private var previewRequiresUserIntent = false

    init(sources: [PhotoSource] = [], access: LibraryAccess = .notDetermined) {
        libraryAccess = access
        self.sources = Self.accessibleIndex(sources, access: access)
    }

    var viewedSourceRevision: String? { viewedSourceID.flatMap { sources[$0]?.resourceRevision } }

    var effectiveSources: [PhotoSource] {
        let ids = isSelecting ? checkedSourceIDs : Set(viewedSourceID.map { [$0] } ?? [])
        return ids.compactMap { sources[$0] }.sorted { lhs, rhs in
            switch (lhs.captureDate, rhs.captureDate) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.id < rhs.id
            }
        }
    }
    var effectiveSourceIDs: [SourceID] { effectiveSources.map(\.id) }

    /// Unknown RAW models remain candidates until original-resource materialization validates them.
    /// Camera busy state and export progress never change source eligibility.
    var eligibleSourceIDs: Set<SourceID> {
        Set(sources.values.compactMap { source in
            if case .incompatible = source.compatibility { return nil }
            return source.id
        })
    }

    var exportDisabledReason: WorkspaceExportDisabledReason? {
        let effective = effectiveSources
        guard !effective.isEmpty else { return .noSources }
        guard let recipe = selectedRecipe else { return .noRecipe }
        for source in effective {
            if case .incompatible(let model) = source.compatibility {
                return .incompatibleSource(sourceID: source.id, model: model)
            }
        }
        if case .unsupported(let issues) = recipe.renderingSupport { return .unsupportedRecipe(issues) }
        guard activeJobID == nil else { return .activeJob }
        guard case .ready(let session) = cameraState else { return .cameraNotReady }
        guard let context = currentCameraExecutionContext, context.generation == session.generation else {
            return .cameraContextUnavailable
        }
        guard matches(recipe: recipe, context: context) else { return .recipeCameraMismatch }
        return nil
    }
    var canExport: Bool { exportDisabledReason == nil }

    @discardableResult
    mutating func reduce(_ action: WorkspaceAction) -> [WorkspaceEffect] {
        switch action {
        case .sourceTapped(let id):
            guard sources[id] != nil else { return [] }
            if isSelecting {
                if !checkedSourceIDs.insert(id).inserted { checkedSourceIDs.remove(id) }
            }
            viewedSourceID = id
            previewRequiresUserIntent = false
            displayedVersion = originalVersion
            wantsRecipePreview = selectedRecipe != nil
            return requestPreview()

        case .select:
            guard !isSelecting else { return [] }
            isSelecting = true
            checkedSourceIDs = Set(viewedSourceID.map { [$0] } ?? [])

        case .done:
            isSelecting = false
            checkedSourceIDs.removeAll()

        case .checkedSourcesReplaced(let ids):
            if isSelecting { checkedSourceIDs = ids.intersection(Set(sources.keys)) }

        case .versionSelected(let version):
            guard viewedSourceID != nil else { return [] }
            if case .preview(let key) = version {
                guard key.sourceID == viewedSourceID,
                      key.sourceRevision == sources[key.sourceID]?.resourceRevision else { return [] }
            }
            invalidatePreview()
            wantsRecipePreview = false
            displayedVersion = version

        case .recipeSelected(let slot):
            previewRequiresUserIntent = false
            if let slot {
                guard let recipe = recipes.first(where: { $0.slot == slot }) else { return [] }
                selectedRecipe = recipe
            } else {
                selectedRecipe = nil
            }
            displayedVersion = originalVersion
            wantsRecipePreview = selectedRecipe != nil
            return requestPreview()

        case .recipesRefreshed(let refreshed):
            guard refreshed.count == 7, Set(refreshed.map(\.slot)) == Set(1...7),
                  Set(refreshed.map(\.id)).count == 7 else {
                recipeRefreshState = .stale("Recipe refresh must contain seven distinct snapshots for C1–C7.")
                return []
            }
            recipes = refreshed.sorted { $0.slot < $1.slot }
            recipeRefreshState = .fresh
            if let slot = selectedRecipe?.slot {
                selectedRecipe = recipes.first { $0.slot == slot }
                guard !previewRequiresUserIntent else { return [] }
                displayedVersion = originalVersion
                wantsRecipePreview = true
                return requestPreview()
            }

        case .recipeRefreshFailed(let message):
            recipeRefreshState = .stale(message)

        case .libraryUpdated(let updated, let access):
            let oldViewed = viewedSourceID.flatMap { sources[$0] }
            sources = Self.accessibleIndex(updated, access: access)
            libraryAccess = access
            checkedSourceIDs.formIntersection(Set(sources.keys))
            if let id = viewedSourceID, sources[id] == nil {
                viewedSourceID = nil
                displayedVersion = nil
                wantsRecipePreview = false
                invalidatePreview()
            } else if let id = viewedSourceID,
                      sources[id]?.resourceRevision != oldViewed?.resourceRevision || sources[id]?.originalResources != oldViewed?.originalResources {
                displayedVersion = originalVersion
                return requestPreview()
            }

        case .cameraChanged(let state, let context):
            guard cameraState != state || currentCameraExecutionContext != context else { return [] }
            let continuesExecution = context == currentCameraExecutionContext &&
                belongsToExecution(cameraState, context: context) && belongsToExecution(state, context: context)
            cameraState = state
            currentCameraExecutionContext = context
            // Render admission/completion publishes busy/ready for the same verified execution.
            // Preserve its pending or satisfied preview; disconnects and context changes supersede it.
            if !continuesExecution { invalidatePreview() }
            return requestUnsatisfiedPreview()

        case .activeJobChanged(let id):
            activeJobID = id

        case .drawerMoved(let detent):
            drawerDetent = detent
            if detent == .collapsed, let id = viewedSourceID { return [.scrollToVisible(sourceID: id)] }

        case .previewInterrupted:
            invalidatePreview()
            previewRequiresUserIntent = true
            wantsRecipePreview = false

        case .previewFallback(let version):
            guard viewedSourceID != nil else { return [] }
            if case .preview(let key) = version {
                guard key.sourceID == viewedSourceID, key.sourceRevision == viewedSourceRevision else { return [] }
            }
            displayedVersion = version

        case .previewCompleted(let request, let key):
            guard pendingPreview == request, request.generation == displayGeneration,
                  wantsRecipePreview, request.sourceID == viewedSourceID,
                  request.recipe.id == selectedRecipe?.id,
                  key.sourceID == request.sourceID, key.sourceRevision == request.sourceRevision,
                  key.settingsDigest == request.recipe.settingsDigest,
                  key.cameraContext == request.cameraContext else { return [] }
            pendingPreview = nil
            previewSatisfied = true
            displayedVersion = .preview(key)
        }
        return []
    }

    func acceptsPreview(_ request: WorkspacePreviewRequest) -> Bool { pendingPreview == request }

    private var originalVersion: VersionID? {
        guard let id = viewedSourceID, let source = sources[id] else { return nil }
        return source.originalResources.jpeg == nil ? .raw : .cameraJPEG
    }

    private mutating func invalidatePreview() {
        displayGeneration &+= 1
        pendingPreview = nil
        previewSatisfied = false
    }

    private mutating func requestPreview() -> [WorkspaceEffect] {
        invalidatePreview()
        return requestUnsatisfiedPreview()
    }

    private mutating func requestUnsatisfiedPreview() -> [WorkspaceEffect] {
        guard !previewSatisfied, pendingPreview == nil,
              wantsRecipePreview, let id = viewedSourceID, let source = sources[id],
              eligibleSourceIDs.contains(id), let recipe = selectedRecipe,
              case .supported = recipe.renderingSupport,
              case .ready(let session) = cameraState,
              let context = currentCameraExecutionContext, context.generation == session.generation,
              matches(recipe: recipe, context: context) else { return [] }
        let request = WorkspacePreviewRequest(generation: displayGeneration, sourceID: id,
            sourceRevision: source.resourceRevision, recipe: recipe, cameraContext: context)
        pendingPreview = request
        return [.requestPreview(request)]
    }

    private func matches(recipe: RecipeSnapshot, context: CameraExecutionContext) -> Bool {
        let imported = recipe.cameraContext
        return imported.model == context.model && imported.firmware == context.firmware &&
            imported.capability == context.capability && context.supportVersion == XT5WorkingProfile.supportVersion
    }

    private func belongsToExecution(_ state: CameraState, context: CameraExecutionContext?) -> Bool {
        guard let context else { return false }
        switch state {
        case .ready(let session), .busy(let session): return session.generation == context.generation
        default: return false
        }
    }

    private static func accessibleIndex(_ sources: [PhotoSource], access: LibraryAccess) -> [SourceID: PhotoSource] {
        guard access == .full || access == .limited else { return [:] }
        return Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
    }
}
