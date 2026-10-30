import FujiCameraCore
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
    /// Day checkbox membership only; can enter selection without changing the viewed photo.
    case daySelectionToggled(Set<SourceID>)
    case photoFilterSelected(PhotoTrayFilter)
    case photoFilterAssessed(PhotoSource, camera: PhotoTrayFilterCamera, result: PhotoTrayAssessment)
    case versionSelected(VersionID)
    case recipeSelected(slot: Int?)
    case phoneRecipeSelected(UUID)
    case phoneRecipeDeleted(UUID)
    case phoneRecipeUpdated(PhoneRecipe)
    case phoneRecipesLoaded([PhoneRecipe])
    case recipesLoaded([RecipeSnapshot],slots:[RecipeSlot])
    case recipesImported(ImportedRecipeCollection)
    case recipeImportStarted
    case cameraResetChanged(Bool)
    case cameraSupportVerified(CameraExecutionContext,VerifiedCameraSupport)
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
    case noSources, noRecipe, activeJob, cameraNotReady, cameraAttention, cameraResetting, cameraContextUnavailable, recipeCameraMismatch
    case incompatibleSource(sourceID: SourceID, model: String)
    case unsupportedRecipe([RecipeRenderingIssue])

    var message: String {
        switch self {
        case .noSources: "Choose a photo to export."
        case .noRecipe: "Choose a recipe to export."
        case .activeJob: "Wait for the current export to finish."
        case .cameraNotReady: "Connect a supported Fujifilm camera and wait for it to be ready."
        case .cameraAttention: "Resolve the camera error before exporting."
        case .cameraResetting: "Wait for the camera connection reset to finish."
        case .cameraContextUnavailable: "Verify the connected camera before exporting."
        case .recipeCameraMismatch: "Refresh recipes from the connected camera."
        case .incompatibleSource(_, let model): "This RAW was captured by \(model) and cannot be converted by the connected camera."
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
    private(set) var photoFilter: PhotoTrayFilter = .allPhotos
    private var photoFilterIndex = PhotoTrayFilterIndex()
    private(set) var drawerDetent: DrawerDetent = .collapsed
    private(set) var recipes: [RecipeSnapshot] = []
    private(set) var recipeSlots:[RecipeSlot] = []
    private(set) var cameraSupport:VerifiedCameraSupport?
    private(set) var phoneRecipes: [PhoneRecipe] = []
    private(set) var recipeRefreshState: RecipeRefreshState = .fresh
    private(set) var currentCameraExecutionContext: CameraExecutionContext?
    private(set) var cameraState: CameraState = .disconnected
    private(set) var isCameraResetting = false
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

    var photoFilterCamera: PhotoTrayFilterCamera? {
        guard isCameraConnected, let support = cameraSupport, let context = currentCameraExecutionContext,
              context.model == support.model, context.firmware == support.firmware,
              context.capability == support.capability, context.supportVersion == support.supportVersion else { return nil }
        return PhotoTrayFilterCamera(support)
    }
    var visibleSourceIDs: Set<SourceID> { Set(sources.keys.filter(sourceIsVisible)) }
    var photoFilterPendingCount: Int {
        guard photoFilter == .compatibleWithCamera, let camera = photoFilterCamera else { return 0 }
        return sources.values.filter { photoFilterIndex.result(for: $0, camera: camera) == nil }.count
    }
    var photoFilterUnavailableCount: Int {
        guard photoFilter == .compatibleWithCamera, let camera = photoFilterCamera else { return 0 }
        return sources.values.filter { photoFilterIndex.result(for: $0, camera: camera) == .unavailable }.count
    }
    func photoFilterNeedsAssessment(_ source: PhotoSource) -> Bool {
        guard photoFilter == .compatibleWithCamera, let camera = photoFilterCamera,
              sources[source.id] == source else { return false }
        return photoFilterIndex.result(for: source, camera: camera) == nil
    }
    private func sourceIsVisible(_ id: SourceID) -> Bool {
        guard let source = sources[id] else { return false }
        guard photoFilter == .compatibleWithCamera else { return true }
        guard let camera = photoFilterCamera else { return false }
        return photoFilterIndex.result(for: source, camera: camera) == .compatible
    }

    var isCameraConnected: Bool {
        switch cameraState {
        case .sessionOpen, .ready, .busy, .attentionRequired: true
        default: false
        }
    }

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
            if incompatibleModel(source) != nil { return nil }
            return source.id
        })
    }

    private var incompatibleSelectionReason: WorkspaceExportDisabledReason? {
        for source in effectiveSources {
            if let model = incompatibleModel(source) {
                return .incompatibleSource(sourceID: source.id, model: model)
            }
        }
        return nil
    }

    var exportDisabledReason: WorkspaceExportDisabledReason? {
        if isCameraResetting { return .cameraResetting }
        let effective = effectiveSources
        guard !effective.isEmpty else { return .noSources }
        guard let recipe = selectedRecipe else { return .noRecipe }
        if let reason = incompatibleSelectionReason { return reason }
        if case .unsupported(let issues) = recipe.renderingSupport(using: RecipeCodecRegistry()) { return .unsupportedRecipe(issues) }
        guard activeJobID == nil else { return .activeJob }
        if case .attentionRequired = cameraState { return .cameraAttention }
        guard case .ready(let session) = cameraState else { return .cameraNotReady }
        guard let context = currentCameraExecutionContext, context.generation == session.generation else {
            return .cameraContextUnavailable
        }
        guard matches(recipe: recipe, context: context) else { return .recipeCameraMismatch }
        return nil
    }
    var canExport: Bool { exportDisabledReason == nil }
    var isCameraReady: Bool {
        guard !isCameraResetting, case .ready = cameraState else { return false }
        return true
    }
    var canImportRecipes: Bool { isCameraReady && cameraSupport?.capabilities.recipeImport == .supported }

    @discardableResult
    mutating func reduce(_ action: WorkspaceAction) -> [WorkspaceEffect] {
        defer {
            if photoFilter == .compatibleWithCamera, !checkedSourceIDs.isEmpty {
                checkedSourceIDs = checkedSourceIDs.filter(sourceIsVisible)
            }
        }
        switch action {
        case .cameraResetChanged(let resetting):
            isCameraResetting = resetting
            return reduce(.previewInterrupted)
        case .sourceTapped(let id):
            guard sourceIsVisible(id) else { return [] }
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

        case .daySelectionToggled(let ids):
            let visible = ids.filter(sourceIsVisible)
            guard !visible.isEmpty else { return [] }
            isSelecting = true
            if visible.isSubset(of: checkedSourceIDs) { checkedSourceIDs.subtract(visible) }
            else { checkedSourceIDs.formUnion(visible) }

        case .photoFilterSelected(let filter):
            guard filter == .allPhotos || photoFilterCamera != nil else { return [] }
            if filter == .compatibleWithCamera, let camera = photoFilterCamera {
                photoFilterIndex.retryUnavailable(camera: camera)
            }
            photoFilter = filter

        case .photoFilterAssessed(let source, let camera, let result):
            guard camera == photoFilterCamera, let current = sources[source.id],
                  OriginalIdentity(current) == OriginalIdentity(source),
                  current.originalResources == source.originalResources else { return [] }
            photoFilterIndex.record(result, source: current, camera: camera)

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
            guard slot == nil || isCameraConnected else { return [] }
            guard slot == nil || incompatibleSelectionReason == nil else { return [] }
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

        case .phoneRecipeSelected(let id):
            guard isCameraConnected, incompatibleSelectionReason == nil,
                  let recipe = phoneRecipes.first(where: { $0.id == id }) else { return [] }
            selectedRecipe = recipe.snapshot
            previewRequiresUserIntent = false
            displayedVersion = originalVersion
            wantsRecipePreview = true
            return requestPreview()

        case .phoneRecipeDeleted(let id):
            guard let recipe = phoneRecipes.first(where: { $0.id == id }) else { return [] }
            phoneRecipes.removeAll { $0.id == id }
            if selectedRecipe?.id == recipe.snapshot.id { return reduce(.recipeSelected(slot: nil)) }

        case .phoneRecipesLoaded(let saved):
            guard saved.allSatisfy({ $0.snapshot.copiedFromRecipeID == $0.id }), Set(saved.map(\.id)).count == saved.count else { return [] }
            phoneRecipes = saved

        case .phoneRecipeUpdated(let updated):
            guard let index = phoneRecipes.firstIndex(where: { $0.id == updated.id }),
                  updated.snapshot.copiedFromRecipeID == updated.id else { return [] }
            let previous = phoneRecipes[index]
            guard previous != updated else { return [] }
            phoneRecipes[index] = updated
            if selectedRecipe?.id == previous.snapshot.id {
                selectedRecipe = updated.snapshot
                previewRequiresUserIntent = false
                displayedVersion = originalVersion
                wantsRecipePreview = true
                return requestPreview()
            }

        case .recipeImportStarted:
            currentCameraExecutionContext=nil
            cameraState = .opening
            invalidatePreview()

        case .cameraSupportVerified(let context,let support):
            guard context == currentCameraExecutionContext,context.model == support.model,
                context.firmware == support.firmware,context.capability == support.capability,
                context.supportVersion == support.supportVersion else { return [] }
            cameraSupport=support

        case .recipesImported(let collection):
            let execution=collection.context,support=collection.support
            guard collection.declaredSlots == support.capabilities.bankSlots,
                support.model == execution.model,support.firmware == execution.firmware,
                support.capability == execution.capability,support.supportVersion == execution.supportVersion,
                collection.recipes.allSatisfy({ $0.cameraContext.model == execution.model && $0.cameraContext.firmware == execution.firmware && $0.cameraContext.capability == execution.capability && $0.cameraContext.sessionIdentity == execution.sessionIdentity && $0.cameraContext.sessionGeneration == execution.generation }) else { return [] }
            let ids=collection.declaredSlots.map(\.id)
            guard Set(ids).count == ids.count,collection.recipes.count == ids.count,
                Set(collection.recipes.map(\.slot)) == Set(ids),Set(collection.recipes.map(\.id)).count == ids.count,
                collection.recipes.allSatisfy({ !$0.isPhoneRecipe }) else { return [] }
            currentCameraExecutionContext=execution;cameraSupport=support
            if !belongsToExecution(cameraState,context:execution) { cameraState = .opening }
            invalidatePreview()
            return reduce(.recipesLoaded(collection.recipes,slots:collection.declaredSlots))

        case .recipesLoaded(let refreshed,let slots):
            let ids=slots.map(\.id)
            guard Set(ids).count == ids.count,refreshed.count == ids.count,Set(refreshed.map(\.slot)) == Set(ids),
                  Set(refreshed.map(\.id)).count == refreshed.count,refreshed.allSatisfy({ !$0.isPhoneRecipe }) else {
                recipeRefreshState = .stale("Recipe refresh must contain every declared camera slot exactly once.")
                return []
            }
            recipeSlots=slots
            recipes = refreshed.sorted { $0.slot < $1.slot }
            recipeRefreshState = .fresh
            if let selectedRecipe, !selectedRecipe.isPhoneRecipe {
                let slot = selectedRecipe.slot
                self.selectedRecipe = recipes.first { $0.slot == slot }
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
            photoFilterIndex.retain(Array(sources.values))
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
            switch state {
            case .disconnected, .authorizationDenied, .wrongMode, .recoverableError:
                photoFilter = .allPhotos
            default: break
            }
            if currentCameraExecutionContext != context {
                // Codec support describes the verified camera's capabilities,
                // so a new session with the same support keeps filter membership.
                let sameSupport: Bool
                if let support = cameraSupport, let context {
                    sameSupport = support.model == context.model && support.firmware == context.firmware &&
                        support.capability == context.capability && support.supportVersion == context.supportVersion
                } else { sameSupport = false }
                if !sameSupport { cameraSupport = nil }
            }
            currentCameraExecutionContext = context
            if case .attentionRequired = state {
                if context == nil { photoFilter = .allPhotos }
                // Keep browsing and the recipe selection, but require an explicit
                // request after recovery rather than replaying the failed preview.
                return reduce(.previewInterrupted)
            }
            if !isCameraConnected, selectedRecipe != nil {
                return reduce(.recipeSelected(slot: nil))
            }
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

    /// The selected recipe is still pending while an earlier camera operation drains.
    var isAwaitingRecipePreview: Bool {
        guard !isCameraResetting, !previewSatisfied, wantsRecipePreview,
              let id = viewedSourceID, let source = sources[id], incompatibleModel(source) == nil,
              let recipe = selectedRecipe,
              case .supported = recipe.renderingSupport(using: RecipeCodecRegistry()),
              let context = currentCameraExecutionContext,
              belongsToExecution(cameraState, context: context), matches(recipe: recipe, context: context) else { return false }
        return true
    }

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
        guard isAwaitingRecipePreview, pendingPreview == nil,
              let id = viewedSourceID, let source = sources[id], let recipe = selectedRecipe,
              let context = currentCameraExecutionContext,
              matches(recipe: recipe, context: context) else { return [] }
        let request = WorkspacePreviewRequest(generation: displayGeneration, sourceID: id,
            sourceRevision: source.resourceRevision, recipe: recipe, cameraContext: context)
        pendingPreview = request
        return [.requestPreview(request)]
    }

    private func incompatibleModel(_ source:PhotoSource) -> String? {
        if let camera = photoFilterCamera,
           photoFilterIndex.result(for: source, camera: camera) == .incompatible {
            switch source.compatibility {
            case .supported(let model), .incompatible(let model): return model
            case .unknown: return camera.model
            }
        }
        switch source.compatibility {
        case .incompatible(let model):return model
        case .supported(let model):return currentCameraExecutionContext.map { $0.model != model ? model : nil } ?? nil
        case .unknown:return nil
        }
    }
    func recipeExecutionReason(_ recipe:RecipeSnapshot) -> String? {
        if isCameraResetting { return "Wait for the camera connection reset to finish." }
        if case .attentionRequired = cameraState { return "Resolve the camera error before converting photos." }
        if let reason = incompatibleSelectionReason { return reason.message }
        if let context=currentCameraExecutionContext,!matches(recipe:recipe,context:context) { return "Requires a compatible \(recipe.targetCamera.rawValue) camera." }
        if case .unsupported(let issues) = recipe.renderingSupport(using:RecipeCodecRegistry()) {
            for case .unsupportedSetting(let id, let value) in issues {
                return "Conversion is unavailable for \(id.title.lowercased()) set to \(id.label(for:value))."
            }
            return "Conversion is unavailable for these settings."
        }
        guard currentCameraExecutionContext != nil,isCameraConnected else { return "Connect a supported Fujifilm camera." }
        return nil
    }
    private func matches(recipe: RecipeSnapshot, context: CameraExecutionContext) -> Bool {
        recipe.targetCamera.matches(context)
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
