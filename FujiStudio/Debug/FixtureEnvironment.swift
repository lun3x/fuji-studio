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
    }
    static func make(access: LibraryAccess = .full, uncertain: Bool = false, cameraOverride: (any CameraServing)? = nil) async throws -> Bundle {
        let images = try WorkspaceFixture()
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
        let reader = FixtureLibrary(sources: originals, image: images.file, root: root, access: access)
        let camera = FixtureCamera(recipes: images.state.recipes, image: images.file, root: root)
        let selectedCamera: any CameraServing = cameraOverride ?? camera
        let writer = FixtureWriter(reader: reader, uncertain: uncertain)
        let pool = OriginalResourcePool(reader: reader, prepare: { local in
            PreparedRAW(fileURL: local.fileURL, sha256: local.checksum, sourceID: local.token.assetID, sourceRevision: local.token.sourceRevision,
                metadata: RAWMetadata(cameraModel: "X-T5", containerGeometry: PixelSize(width: 1800, height: 1200), recordedGeometry: PixelSize(width: 1800, height: 1200), recordedAspect: PixelSize(width: 3, height: 2), cropTop: 0, cropLeft: 0, orientation: 1))
        })
        let scheduler = CameraWorkScheduler()
        let resolver = VersionImageResolver(library: reader, catalog: storage.0, pool: pool, rawRenderer: storage.2, cache: storage.1)
        let preview = PreviewCoordinator(pool: pool, camera: selectedCamera, scheduler: scheduler, cache: storage.1, rawRenderer: storage.2,
            storedDisplay: { source, version, progress in try await resolver.resolve(source: source, version: version, progress: progress).lease })
        let exports = ExportCoordinator(reader: reader, camera: selectedCamera, catalog: storage.0, writer: writer, pool: pool, cache: storage.1, scheduler: scheduler)
        let platform = FixturePlatform()
        // Cached recipes exercise useful disconnected browsing, without selecting a recipe.
        try await storage.0.replaceRecipes(images.state.recipes)
        return Bundle(environment: AppEnvironment(reader: reader, camera: selectedCamera, catalog: storage.0, originals: pool, preview: preview,
            resolver: resolver, exports: exports, cache: storage.1, thumbnails: images.thumbnails, platform: platform),
            reader: reader, camera: camera, writer: writer, platform: platform)
    }
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
    private var discoveryLimit: Int?
    private var revisionBytes: [String: Data] = [:]
    private(set) var materializations = 0
    private var observers: [AsyncStream<LibraryChange>.Continuation] = []
    private(set) var rawReads = 0, changeSubscriptions = 0, discoveryRequests = 0
    init(sources: [PhotoSource], image: DisplayFileLease, root: URL, access: LibraryAccess) {
        index = sources; self.image = image; self.root = root; self.access = access
    }
    func requestAccess() -> LibraryAccess { access }
    func setAccess(_ value: LibraryAccess) { access = value }
    func restrictTo(_ ids: Set<String>) { index = index.filter { ids.contains($0.id) }; access = .limited }
    func holdDiscovery(_ barrier: FixtureBarrier) { discoveryBarrier = barrier }
    func limitDiscovery(_ count: Int) { discoveryLimit = count }
    func holdMaterialize(_ id: String, barrier: FixtureBarrier) { materializeBarriers[id] = barrier }
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
        let bytes = try revisionBytes[resource.sourceRevision] ?? Data(contentsOf: image.fileURL)
        if let barrier = materializeBarriers[resource.assetID] { await barrier.wait() }
        try Task.checkCancellation()
        if resource.format == .raf { rawReads += 1 }
        let url = root.appendingPathComponent("transfer-\(UUID().uuidString).JPG")
        try bytes.write(to: url)
        materializations += 1
        progress(1)
        return LocalResource(token: resource, fileURL: url, checksum: try ResourceChecksum.sha256(url))
    }
    func addOutput(_ id: String) {
        outputs[id] = ResourceToken(assetID: id, role: .primaryOriginal, contentTypeIdentifier: "public.jpeg", format: .jpeg, originalFilename: "generated.JPG", discriminator: "jpeg", sourceRevision: "generated")
    }
}

actor FixtureCamera: CameraServing {
    private let snapshots: [RecipeSnapshot], image: DisplayFileLease, root: URL
    private var context: CameraExecutionContext
    private var state: CameraState = .disconnected
    private var observers: [AsyncStream<CameraState>.Continuation] = []
    private var shouldFailImport = false
    private var shouldFailRender = false
    private var renderBarrier: FixtureBarrier?
    private var connectBarrier: FixtureBarrier?
    private var connectionFailure: CameraServiceError?
    private var disconnectBarrier: FixtureBarrier?
    private(set) var cancelledRenders = 0
    private(set) var subscriptions = 0, importCount = 0, connectCount = 0, disconnectCount = 0, renderCount = 0
    var session: CameraSession { CameraSession(generation: context.generation, connection: CameraConnection(name: "Fixture X-T5", usbVendorID: 0, usbProductID: 0)) }
    init(recipes: [RecipeSnapshot], image: DisplayFileLease, root: URL) {
        snapshots = recipes; self.image = image; self.root = root
        context = CameraExecutionContext(model: "X-T5", firmware: "4.31", capability: "X-T5_0200", supportVersion: XT5WorkingProfile.supportVersion, sessionIdentity: UUID(), generation: 0)
    }
    func executionContext() throws -> CameraExecutionContext {
        switch state { case .ready, .busy: return context; default: throw CameraServiceError.notReady }
    }
    func states() -> AsyncStream<CameraState> { subscriptions += 1; return AsyncStream { observers.append($0); $0.yield(state) } }
    private func emit(_ next: CameraState) { state = next; observers.forEach { $0.yield(next) } }
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
    func cycleBusyReady() { emit(.busy(session)); emit(.ready(session)) }
    func holdRender(_ barrier: FixtureBarrier) { renderBarrier = barrier }
    func failRender() { shouldFailRender = true }
    func failImport() { shouldFailImport = true }
    func importRecipes() async throws -> [RecipeSnapshot] {
        importCount += 1; emit(.busy(session)); await Task.yield(); defer { emit(.ready(session)) }
        if shouldFailImport { throw CameraServiceError.recipeImportFailed(restorationConfirmed: true) }
        return snapshots.map { s in RecipeSnapshot(id: UUID(), slot: s.slot, name: s.name, importedName: s.importedName,
            importedSettings: s.importedSettings, settingsDigest: s.settingsDigest,
            cameraContext: RecipeCameraContext(model: context.model, firmware: context.firmware, capability: context.capability, sessionIdentity: context.sessionIdentity, sessionGeneration: context.generation), importedAt: Date(), renderingIssues: s.renderingIssues) }
    }
    func render(raw: PreparedRAW, recipe: RecipeSnapshot, policy: OutputPolicy) async throws -> CameraJPEG {
        _ = try executionContext(); renderCount += 1; emit(.busy(session)); await Task.yield()
        if let renderBarrier { await renderBarrier.wait() }
        if Task.isCancelled { cancelledRenders += 1; throw CancellationError() }
        if shouldFailRender { shouldFailRender = false; emit(.disconnected); throw CameraServiceError.uncertainOperation(UUID()) }
        defer { emit(.ready(session)) }
        let url = root.appendingPathComponent("render-\(UUID().uuidString).JPG")
        try FileManager.default.copyItem(at: image.fileURL, to: url)
        let normalized = try recipe.normalizedSettings
        let key = RenderKey(sourceID: raw.sourceID, sourceRevision: raw.sourceRevision, sourceSHA256: raw.sha256, settingsDigest: recipe.settingsDigest, cameraContext: context, width: 1800, height: 1200, orientation: 1, policy: policy, quality: .fullResolutionFine)
        return CameraJPEG(fileURL: url, sourceID: raw.sourceID, sourceRevision: raw.sourceRevision, sourceSHA256: raw.sha256,
            recipeSnapshotID: recipe.id, settingsDigest: recipe.settingsDigest, cameraContext: context, operationID: UUID(), width: 1800, height: 1200, orientation: 1, quality: .fullResolutionFine,
            effectiveRecipe: EffectiveRecipeReport(supportVersion: normalized.supportVersion, requested: normalized, dormantGrainSizeNotSerialized: false, inactiveKelvinPreserved: false, lensOptimizerRequested: true, lensOptimizerEffective: true, lensOptimizerAdjusted: false, evidence: "Synthetic UI fixture; not camera evidence"),
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
#endif
