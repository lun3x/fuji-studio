import FujiCameraCore
#if DEBUG
import SwiftUI
import UIKit
import Observation

/// All deterministic UI routes are decided before ANY live service or probe is constructed.
@MainActor enum FixtureEnvironment {
    enum Route: Equatable { case unitHost, flow, workspace, grid, viewer, probe, live, liveAcceptance(UUID), invalid }
    static func route(arguments: [String], unitHost: Bool) -> Route {
        if unitHost { return .unitHost }
        if arguments.contains("--live-acceptance-run") {
            guard arguments.filter({ $0 == "--live-acceptance-run" }).count == 1,
                  let index = arguments.firstIndex(of: "--live-acceptance-run"), index + 1 < arguments.count,
                  let id = UUID(uuidString: arguments[index + 1]),
                  !arguments.contains(where: { $0 != "--live-acceptance-run" && ($0.hasSuffix("-probe") || $0.contains("fixture")) }) else { return .invalid }
            return .liveAcceptance(id)
        }
        let fixtures = arguments.filter { ["--ui-fixtures", "--workspace-fixture", "--grid-fixture", "--viewer-fixture"].contains($0) }
        let probe = arguments.contains { $0.hasPrefix("--") && $0.hasSuffix("-probe") }
        guard fixtures.count <= 1, !(probe && !fixtures.isEmpty) else { return .invalid }
        switch fixtures.first {
        case "--ui-fixtures": return .flow
        case "--workspace-fixture": return .workspace
        case "--grid-fixture": return .grid
        case "--viewer-fixture": return .viewer
        default: return probe ? .probe : .live
        }
    }
    struct Bundle {
        let environment: AppEnvironment
        let reader: FixtureLibrary
        let camera: FixtureCamera
        let writer: FixtureWriter
        let platform: FixturePlatform
        let scheduler: CameraWorkScheduler
    }
    static func make(access: LibraryAccess = .full, uncertain: Bool = false, cameraOverride: (any CameraServing)? = nil,cameraModel:String="X-T5",slotCount:Int=7,mixedModels:Bool=false,undecodableRAW:Bool=false,filterSources:Bool=false) async throws -> Bundle {
        let images = try WorkspaceFixture()
        let allRecipes=cameraModel == "X-E3" ? try fixtureXE3Snapshots() : images.state.recipes
        let cachedRecipes=Array(allRecipes.prefix(slotCount))
        let slots=cachedRecipes.map { RecipeSlot(id:$0.slot,label:"C\($0.slot)") }
        let originals = Array(images.sources.prefix(3)).enumerated().map { offset, s in
            var raw = s.originalResources.raf; raw.sourceRevision = s.resourceRevision
            var jpeg = s.originalResources.jpeg; jpeg?.sourceRevision = s.resourceRevision
            return PhotoSource(id: s.id, originalResources: OriginalResources(raf: raw, jpeg: offset == 1 ? nil : jpeg),
                captureDate: Date(timeIntervalSince1970: Double(3 - offset)), location: nil, resourceRevision: s.resourceRevision)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FujiStudioFlow-\(UUID().uuidString)")
        let storage = try await Task.detached {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return (try SwiftDataCatalog(storeURL: root.appendingPathComponent("catalog.store")),
                try FileRenderCache(directory: root.appendingPathComponent("cache"), pinnedDirectory: root.appendingPathComponent("pins"), validateJPEG: { _ in }),
                try RawDisplayRenderer(directory: root.appendingPathComponent("raw-display")))
        }.value
        let metadata: @Sendable (ResourceToken) -> RAWMetadata = { token in
            filterSources ? fixtureFilterMetadata(sourceID: token.assetID, cameraModel: cameraModel) : RAWMetadata(cameraModel: cameraModel, containerGeometry: PixelSize(width: 1800, height: 1200), recordedGeometry: PixelSize(width: 1800, height: 1200), recordedAspect: PixelSize(width: 3, height: 2), cropTop: 0, cropLeft: 0, orientation: 1)
        }
        let reader = FixtureLibrary(sources: originals, image: images.file, root: root, access: access,undecodableRAW:undecodableRAW, metadata: metadata)
        let camera = FixtureCamera(recipes: cachedRecipes, image: images.file, root: root,declaredSlots:slots)
        let selectedCamera: any CameraServing = cameraOverride ?? camera
        let writer = FixtureWriter(reader: reader, uncertain: uncertain)
        let pool = OriginalResourcePool(reader: reader, prepare: { local in
            PreparedRAW(fileURL: local.fileURL, sha256: local.checksum, sourceID: local.token.assetID, sourceRevision: local.token.sourceRevision,
                metadata: metadata(local.token))
        })
        let scheduler = CameraWorkScheduler()
        let resolver = VersionImageResolver(library: reader, catalog: storage.0, pool: pool, rawRenderer: storage.2, cache: storage.1)
        let preview = PreviewCoordinator(pool: pool, camera: selectedCamera, scheduler: scheduler, cache: storage.1, rawRenderer: storage.2,
            storedDisplay: { source, version, progress in try await resolver.resolve(source: source, version: version, progress: progress).lease })
        let exports = ExportCoordinator(reader: reader, camera: selectedCamera, catalog: storage.0, writer: writer, pool: pool, cache: storage.1, scheduler: scheduler)
        let platform = FixturePlatform()
        // Cached recipes exercise useful disconnected browsing, without selecting a recipe.
        try await storage.0.replaceRecipes(try await camera.cachedRecipeCollection())
        if mixedModels,let other=images.state.recipes.first { _ = try await storage.0.copyRecipeToPhone(other) }
        return Bundle(environment: AppEnvironment(reader: reader, camera: selectedCamera, catalog: storage.0, originals: pool, preview: preview,
            resolver: resolver, exports: exports, cache: storage.1, thumbnails: images.thumbnails, platform: platform),
            reader: reader, camera: camera, writer: writer, platform: platform, scheduler: scheduler)
    }
}

/// Mixed RAW metadata for filter validation; pixels remain generated fixture JPEGs.
private func fixtureFilterMetadata(sourceID: SourceID, cameraModel: String) -> RAWMetadata {
    let model = sourceID == "source-1" ? (cameraModel == "X-E3" ? "X-T5" : "X-E3") : cameraModel
    let valid = sourceID != "source-2"
    if model == "X-E3" {
        return RAWMetadata(cameraModel: model, containerGeometry: .init(width: 6048, height: 4038),
            recordedGeometry: .init(width: valid ? 6000 : 3000, height: valid ? 4000 : 2000),
            recordedAspect: .init(width: 3, height: 2), cropTop: 21, cropLeft: 16, orientation: 1,
            compression: .lossless, bitDepth: 14, rafVersion: "0130")
    }
    return RAWMetadata(cameraModel: model, containerGeometry: .init(width: 7872, height: 5196),
        recordedGeometry: .init(width: valid ? 7728 : 3000, height: valid ? 5152 : 2000),
        recordedAspect: .init(width: 3, height: 2), cropTop: 21, cropLeft: 12, orientation: 1)
}

actor FixtureBarrier {
    private var open = false
    private var waiting = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async { waiting = true; if open { return }; await withCheckedContinuation { continuations.append($0) } }
    func entered() async { while !waiting { await Task.yield() } }
    func release() { open = true; continuations.forEach { $0.resume() }; continuations = [] }
}

actor FixtureLibrary: PhotoLibraryReading {
    private var index: [PhotoSource]
    private var access: LibraryAccess
    private let image: DisplayFileLease, root: URL
    private var outputs: [String: ResourceToken] = [:]
    private var resourcesBarrier: FixtureBarrier?
    private var discoveryBarrier: FixtureBarrier?
    private var materializeBarriers: [String: FixtureBarrier] = [:]
    private var materializeFailures: [String: ResourceError] = [:]
    private var discoveryLimit: Int?
    private var revisionBytes: [String: Data] = [:]
    private(set) var materializations = 0
    private var observers: [AsyncStream<LibraryChange>.Continuation] = []
    private(set) var rawReads = 0, changeSubscriptions = 0, discoveryRequests = 0
    private let metadata: @Sendable (ResourceToken) -> RAWMetadata
    private(set) var metadataReads = 0
    init(sources: [PhotoSource], image: DisplayFileLease, root: URL, access: LibraryAccess,undecodableRAW:Bool=false, metadata: @escaping @Sendable (ResourceToken) -> RAWMetadata) {
        index = sources; self.image = image; self.root = root; self.access = access;self.undecodableRAW=undecodableRAW
        self.metadata = metadata
    }
    func requestAccess() -> LibraryAccess { access }
    func setAccess(_ value: LibraryAccess) { access = value }
    func restrictTo(_ ids: Set<String>) { index = index.filter { ids.contains($0.id) }; access = .limited }
    func holdDiscovery(_ barrier: FixtureBarrier) { discoveryBarrier = barrier }
    func limitDiscovery(_ count: Int) { discoveryLimit = count }
    func holdMaterialize(_ id: String, barrier: FixtureBarrier) { materializeBarriers[id] = barrier }
    func failMaterialize(_ id: String, error: ResourceError?) { materializeFailures[id] = error }
    private var undecodableRAW=false
    func replaceOriginal(_ id: String, revision: String) throws -> Data {
        guard let i = index.firstIndex(where: { $0.id == id }) else { throw ResourceError.inaccessibleAsset(id) }
        let old = index[i]
        var raw = old.originalResources.raf, jpeg = old.originalResources.jpeg
        raw.sourceRevision = revision; jpeg?.sourceRevision = revision
        index[i] = PhotoSource(id: id, originalResources: .init(raf: raw, jpeg: jpeg), captureDate: old.captureDate,
            location: old.location, resourceRevision: revision)
        var bytes = try Data(contentsOf: image.fileURL); bytes.append(Data(revision.utf8))
        revisionBytes[revision] = bytes; materializeBarriers[id] = nil
        return bytes
    }
    func removeOutput(_ id: String, notify: Bool = true) { outputs[id] = nil; if notify { observers.forEach { $0.yield(LibraryChange(changedIDs: [], removedIDs: [id], accessScopeChanged: false)) } } }
    func sources() -> AsyncThrowingStream<[PhotoSource], Error> {
        discoveryRequests += 1
        let values = Array(index.prefix(discoveryLimit ?? index.count)), barrier = discoveryBarrier
        return AsyncThrowingStream { c in
            let task = Task {
                for (i, source) in values.enumerated() {
                    c.yield([source])
                    if i == 0, let barrier { await barrier.wait() }
                }
                c.finish()
            }
            c.onTermination = { _ in task.cancel() }
        }
    }
    func source(id: SourceID) throws -> PhotoSource {
        guard access == .full || access == .limited else { throw ResourceError.authorization(access) }
        guard let source = index.first(where: { $0.id == id }) else { throw ResourceError.inaccessibleAsset(id) }; return source
    }
    func holdResources(_ barrier: FixtureBarrier) { resourcesBarrier = barrier }
    func resources(assetID: String) async throws -> [ResourceToken] {
        if let resourcesBarrier { await resourcesBarrier.wait() }
        if let output = outputs[assetID] { return [output] }
        let source = try source(id: assetID); return [source.originalResources.raf] + (source.originalResources.jpeg.map { [$0] } ?? [])
    }
    func changes() -> AsyncStream<LibraryChange> {
        changeSubscriptions += 1
        return AsyncStream { observers.append($0) }
    }
    func materialize(_ resource: ResourceToken, progress: @escaping @Sendable (Double) -> Void) async throws -> LocalResource {
        let bytes = resource.format == .raf && undecodableRAW ? Data(repeating:42,count:256) : try revisionBytes[resource.sourceRevision] ?? Data(contentsOf: image.fileURL)
        if let barrier = materializeBarriers[resource.assetID] { await barrier.wait() }
        try Task.checkCancellation()
        if let error = materializeFailures[resource.assetID] { throw error }
        if resource.format == .raf { rawReads += 1 }
        let url = root.appendingPathComponent("transfer-\(UUID().uuidString).JPG")
        try bytes.write(to: url)
        materializations += 1
        progress(1)
        return LocalResource(token: resource, fileURL: url, checksum: try ResourceChecksum.sha256(url))
    }
    func rawMetadata(_ resource: ResourceToken) async throws -> RAWMetadata {
        if let barrier = materializeBarriers[resource.assetID] { await barrier.wait() }
        try Task.checkCancellation()
        if let error = materializeFailures[resource.assetID] { throw error }
        metadataReads += 1
        return metadata(resource)
    }
    func addOutput(_ id: String) {
        outputs[id] = ResourceToken(assetID: id, role: .primaryOriginal, contentTypeIdentifier: "public.jpeg", format: .jpeg, originalFilename: "generated.JPG", discriminator: "jpeg", sourceRevision: "generated")
    }
}

actor FixtureCamera: CameraServing {
    func support(for expected: CameraExecutionContext) throws -> VerifiedCameraSupport {
        let current = try executionContext()
        guard current == expected else { throw CameraServiceError.unsupportedContext }
        return try declaredSupport(current)
    }

    private let snapshots: [RecipeSnapshot], image: DisplayFileLease, root: URL
    private let declaredSlots:[RecipeSlot]
    private func declaredSupport(_ context:CameraExecutionContext) throws -> VerifiedCameraSupport {
        let base=try fixtureCameraSupport(context),c=base.capabilities
        return .init(adapterID:base.adapterID,model:base.model,firmware:base.firmware,capability:base.capability,capabilityOrigin:base.capabilityOrigin,supportVersion:base.supportVersion,
            capabilities:.init(bankSlots:declaredSlots,settings:c.settings,recipeImport:c.recipeImport,sourceConstraints:c.sourceConstraints))
    }
    private var context: CameraExecutionContext
    private var state: CameraState = .disconnected
    private var observers: [AsyncStream<CameraState>.Continuation] = []
    private var deferredNotifications: [CameraState]?
    private var shouldFailImport = false
    private var importAttention: String?
    private var shouldFailRender = false
    private var shouldFailRenderWithoutDisconnect = false
    private var renderAttention: String?
    private var resetFailure: CameraServiceError?
    private var reopenBeforeResetFailure = false
    private var resetBarrier: FixtureBarrier?
    private var renderBarrier: FixtureBarrier?
    private var connectBarrier: FixtureBarrier?
    private var importBarrier: FixtureBarrier?
    private var connectionFailure: CameraServiceError?
    private var disconnectBarrier: FixtureBarrier?
    private(set) var cancelledRenders = 0
    private(set) var renderRequests: [(sourceID: SourceID, recipeID: UUID)] = []
    private(set) var subscriptions = 0, importCount = 0, connectCount = 0, disconnectCount = 0, renderCount = 0, resetCount = 0
    var session: CameraSession { CameraSession(generation: context.generation, connection: CameraConnection(name: "Fixture \(context.model)", usbVendorID: 0, usbProductID: 0)) }
    init(recipes: [RecipeSnapshot], image: DisplayFileLease, root: URL,declaredSlots:[RecipeSlot]?=nil) {
        snapshots = recipes; self.image = image; self.root = root
        self.declaredSlots=declaredSlots ?? recipes.map { .init(id:$0.slot,label:"C\($0.slot)") }
        let first=recipes.first?.cameraContext
        context = CameraExecutionContext(model:first?.model ?? "X-T5",firmware:first?.firmware ?? "4.31",capability:first?.capability ?? "X-T5_0200",supportVersion:first?.model == "X-E3" ? XE3Support.conversionVersion : XT5WorkingProfile.supportVersion,sessionIdentity:UUID(),generation:0)
    }
    func executionContext() throws -> CameraExecutionContext {
        switch state { case .ready, .busy, .attentionRequired: return context; default: throw CameraServiceError.notReady }
    }
    func states() -> AsyncStream<CameraState> { subscriptions += 1; return AsyncStream { observers.append($0); $0.yield(state) } }
    private func emit(_ next: CameraState) {
        state = next
        if deferredNotifications != nil { deferredNotifications?.append(next) }
        else { observers.forEach { $0.yield(next) } }
    }
    func deferStateNotifications() { deferredNotifications = [] }
    func resumeStateNotifications() {
        let pending = deferredNotifications ?? []
        deferredNotifications = nil
        for event in pending { observers.forEach { $0.yield(event) } }
    }
    func setConnectionFailure(_ failure: CameraServiceError?) { connectionFailure = failure }
    func holdConnect(_ barrier: FixtureBarrier) { connectBarrier = barrier }
    func connect() async throws {
        connectCount += 1
        if let connectBarrier { await connectBarrier.wait() }
        try Task.checkCancellation()
        if let connectionFailure { emit(.disconnected); throw connectionFailure }
        context = CameraExecutionContext(model: context.model, firmware: context.firmware, capability: context.capability, supportVersion: context.supportVersion, sessionIdentity: UUID(), generation: context.generation + 1)
        emit(.ready(session))
    }
    func holdDisconnect(_ barrier: FixtureBarrier) { disconnectBarrier = barrier }
    func disconnect() async { disconnectCount += 1; if let disconnectBarrier { await disconnectBarrier.wait() }; emit(.disconnected) }
    func holdReset(_ barrier: FixtureBarrier) { resetBarrier = barrier }
    func failReset(_ error: CameraServiceError?) { resetFailure = error }
    func failResetAfterReopening(_ error: CameraServiceError) { resetFailure = error; reopenBeforeResetFailure = true }
    func resetConnection() async throws {
        resetCount += 1
        emit(.opening)
        if let resetBarrier { await resetBarrier.wait() }
        if let resetFailure {
            if reopenBeforeResetFailure {
                context = CameraExecutionContext(model: context.model, firmware: context.firmware, capability: context.capability, supportVersion: context.supportVersion, sessionIdentity: UUID(), generation: context.generation + 1)
            }
            emit(.attentionRequired(session, message: "The camera could not clear its temporary converted photo."))
            throw resetFailure
        }
        try await connect()
    }
    func cycleBusyReady() { emit(.busy(session)); emit(.ready(session)) }
    func holdRender(_ barrier: FixtureBarrier) { renderBarrier = barrier }
    func failRender() { shouldFailRender = true }
    func failRenderWithoutDisconnect() { shouldFailRenderWithoutDisconnect = true }
    func failRenderWithAttention(_ message: String) { renderAttention = message }
    func failImport() { shouldFailImport = true }
    func failImportWithAttention(_ message: String) { importAttention = message }
    func holdImport(_ barrier: FixtureBarrier) { importBarrier = barrier }
    func cachedRecipeCollection() throws -> ImportedRecipeCollection {
        guard let first=snapshots.first?.cameraContext else { throw CatalogError.invalidRecipeCollection }
        let cached=CameraExecutionContext(model:first.model,firmware:first.firmware,capability:first.capability,
            supportVersion:try RecipeCodecRegistry().supportVersion(for:first),sessionIdentity:first.sessionIdentity,generation:first.sessionGeneration)
        let support=try declaredSupport(cached)
        return .init(recipes:snapshots,declaredSlots:support.capabilities.bankSlots,context:cached,support:support)
    }
    func importRecipes() async throws -> ImportedRecipeCollection {
        importCount += 1; emit(.busy(session)); await Task.yield()
        defer { if case .busy = state { emit(.ready(session)) } }
        if let importBarrier { await importBarrier.wait() }
        if let message = importAttention {
            importAttention = nil
            emit(.attentionRequired(session, message: message))
            throw CameraServiceError.invalidOutput
        }
        if shouldFailImport { throw CameraServiceError.recipeImportFailed(restorationConfirmed: true) }
        if context.model == "X-E3" {
            context = .init(model:context.model,firmware:context.firmware,capability:context.capability,supportVersion:context.supportVersion,sessionIdentity:UUID(),generation:context.generation+2)
        }
        let recipes = snapshots.map { s in RecipeSnapshot(id: UUID(), slot: s.slot, name: s.name, importedName: s.importedName,
            importedSettings: s.importedSettings, settingsDigest: s.settingsDigest,
            cameraContext: RecipeCameraContext(model: context.model, firmware: context.firmware, capability: context.capability, sessionIdentity: context.sessionIdentity, sessionGeneration: context.generation), importedAt: Date(), renderingIssues: s.renderingIssues) }
        let support=try support(for:context)
        return .init(recipes:recipes,declaredSlots:support.capabilities.bankSlots,context:context,support:support)
    }
    func render(raw: PreparedRAW, recipe: RecipeSnapshot, policy: OutputPolicy) async throws -> CameraJPEG {
        guard case .ready = state else { throw CameraServiceError.notReady }
        renderRequests.append((raw.sourceID, recipe.id))
        renderCount += 1; emit(.busy(session)); await Task.yield()
        if let renderBarrier { await renderBarrier.wait() }
        if Task.isCancelled { cancelledRenders += 1; throw CancellationError() }
        if shouldFailRender { shouldFailRender = false; emit(.disconnected); throw CameraServiceError.uncertainOperation(UUID()) }
        if shouldFailRenderWithoutDisconnect { shouldFailRenderWithoutDisconnect = false; emit(.ready(session)); throw CameraServiceError.storage }
        if let message = renderAttention {
            renderAttention = nil
            emit(.attentionRequired(session, message: message))
            throw CameraServiceError.invalidOutput
        }
        defer { emit(.ready(session)) }
        let url = root.appendingPathComponent("render-\(UUID().uuidString).JPG")
        try FileManager.default.copyItem(at: image.fileURL, to: url)
        let normalized = try recipe.settings(using: RecipeCodecRegistry())
        let key = RenderKey(sourceID: raw.sourceID, sourceRevision: raw.sourceRevision, sourceSHA256: raw.sha256, settingsDigest: recipe.settingsDigest, cameraContext: context, width: 1800, height: 1200, orientation: 1, policy: policy, quality: .fullResolutionFine)
        return CameraJPEG(fileURL: url, sourceID: raw.sourceID, sourceRevision: raw.sourceRevision, sourceSHA256: raw.sha256,
            recipeSnapshotID: recipe.id, settingsDigest: recipe.settingsDigest, cameraContext: context, operationID: UUID(), width: 1800, height: 1200, orientation: 1, quality: .fullResolutionFine,
            effectiveRecipe: EffectiveRecipeReport(supportVersion: context.supportVersion, requested: normalized, dormantGrainSizeNotSerialized: false, inactiveKelvinPreserved: false, lensOptimizerRequested: true, lensOptimizerEffective: true, lensOptimizerAdjusted: false, evidence: "Synthetic UI fixture; not camera evidence"),
            baselineSHA256: "synthetic", candidateSHA256: "synthetic", outputSHA256: try ResourceChecksum.sha256(url), key: key)
    }
}

actor FixtureWriter: PhotoLibraryWriting {
    private let reader: FixtureLibrary
    private var uncertain: Bool
    private var barrier: FixtureBarrier?
    private(set) var requests: [PhotoSaveRequest] = []
    private var found: [UUID: SavedAsset] = [:]
    init(reader: FixtureLibrary, uncertain: Bool) { self.reader = reader; self.uncertain = uncertain }
    func holdSave(_ barrier: FixtureBarrier) { self.barrier = barrier }
    func saveJPEG(_ request: PhotoSaveRequest, onPlaceholder: @escaping @Sendable (String) -> Void) async throws -> SavedAsset {
        requests.append(request)
        let id = "fixture-export-\(request.operationID.uuidString)"; onPlaceholder(id)
        if let barrier { await barrier.wait() }
        if uncertain { throw PhotoLibraryWriteError.uncertain(.missingConfirmation) }
        await reader.addOutput(id)
        return SavedAsset(assetID: id, operationID: request.operationID, photosGeometry: nil)
    }
    func makeSubmittedExportDiscoverable(_ operationID: UUID) async throws -> SavedAsset {
        guard requests.contains(where: { $0.operationID == operationID }) else { throw ResourceError.inaccessibleAsset("unsubmitted") }
        let asset = SavedAsset(assetID: "fixture-export-\(operationID.uuidString)", operationID: operationID, photosGeometry: nil)
        await reader.addOutput(asset.assetID); found[operationID] = asset
        return asset
    }
    func findExport(operationID: UUID, knownAssetID: String?) -> SaveLookup {
        guard let asset = found[operationID], knownAssetID == nil || knownAssetID == asset.assetID else { return .notFound }
        return .found(asset)
    }
}

@MainActor @Observable final class FixturePlatform: AppPlatform {
    var idleTimerDisabled = false
    var settingsCalls = 0
    var manageCalls = 0
    func openSettings() { settingsCalls += 1 }
    func managePhotos() { manageCalls += 1 }
}
func fixtureCameraSupport(_ context: CameraExecutionContext) throws -> VerifiedCameraSupport {
    let recipeContext=RecipeCameraContext(model:context.model,firmware:context.firmware,capability:context.capability,sessionIdentity:context.sessionIdentity,sessionGeneration:context.generation)
    return .init(adapterID:.init(rawValue:"fixture"),model:context.model,firmware:context.firmware,capability:context.capability,capabilityOrigin:.applicationDefined,supportVersion:context.supportVersion,capabilities:try RecipeCodecRegistry().capabilities(for:recipeContext))
}
#endif
