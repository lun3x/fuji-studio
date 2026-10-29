@testable import FujiCameraCore
import Foundation
@testable import FujiStudio

struct RenderFixture: Sendable {
    let root: URL, raw: PreparedRAW, recipe: RecipeSnapshot, context: CameraExecutionContext
    init() throws {
        let f = try ProductionOperationFixture()
        root = f.directory; raw = f.raw; recipe = f.profile.bank; context = f.context
    }
    var source: PhotoSource {
        PhotoSource(id: raw.sourceID, originalResources: .init(raf: token, jpeg: nil), captureDate: nil, location: nil, resourceRevision: raw.sourceRevision)
    }
    var token: ResourceToken { ResourceToken(assetID: raw.sourceID, role: .primaryOriginal, contentTypeIdentifier: "com.fuji.raw-image", format: .raf, originalFilename: "synthetic.RAF", discriminator: "raw", sourceRevision: raw.sourceRevision) }
    func key(hash: String? = nil, revision: String? = nil, context: CameraExecutionContext? = nil, width: Int? = nil, digest: String? = nil) -> RenderKey {
        RenderKey(sourceID: raw.sourceID, sourceRevision: revision ?? raw.sourceRevision, sourceSHA256: hash ?? raw.sha256, settingsDigest: digest ?? recipe.settingsDigest, cameraContext: context ?? self.context, width: width ?? raw.metadata.recordedGeometry.width, height: raw.metadata.recordedGeometry.height, orientation: raw.metadata.orientation, policy: .fullSizeFineRecordedGeometry, quality: .fullResolutionFine)
    }
    func jpeg(key: RenderKey? = nil, count: Int = 40) throws -> CameraJPEG {
        let key = key ?? self.key(), url = root.appendingPathComponent(UUID().uuidString + ".JPG")
        try Data(repeating: 45, count: count).write(to: url)
        let normalized = try recipe.settings(using: RecipeCodecRegistry())
        return CameraJPEG(fileURL: url, sourceID: key.sourceID, sourceRevision: key.sourceRevision, sourceSHA256: key.sourceSHA256, recipeSnapshotID: recipe.id, settingsDigest: key.settingsDigest, cameraContext: key.cameraContext, operationID: UUID(), width: key.width, height: key.height, orientation: key.orientation, quality: .fullResolutionFine, effectiveRecipe: .init(supportVersion: key.cameraContext.supportVersion, requested: normalized, dormantGrainSizeNotSerialized: false, inactiveKelvinPreserved: false, lensOptimizerRequested: true, lensOptimizerEffective: false, lensOptimizerAdjusted: true, evidence: "synthetic"), baselineSHA256: "baseline", candidateSHA256: "candidate", outputSHA256: try ResourceChecksum.sha256(url), key: key)
    }
    func cache(budget: Int = 100) throws -> FileRenderCache { try FileRenderCache(directory: root.appendingPathComponent("cache"), pinnedDirectory: root.appendingPathComponent("support"), unpinnedBudget: budget, validateJPEG: { _ in }) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

actor RenderLatch {
    private var open = false
    private var waiting = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async { waiting += 1; if open { return }; await withCheckedContinuation { continuations.append($0) } }
    func release() { open = true; continuations.forEach { $0.resume() }; continuations = [] }
    func entered() async { while waiting == 0 { await Task.yield() } }
}

actor RenderLibrary: PhotoLibraryReading {
    let fixture: RenderFixture
    var count = 0
    var metadataReads = 0
    var metadataOverride: RAWMetadata?
    func setMetadata(_ metadata: RAWMetadata) { metadataOverride = metadata }
    var metadataFailure: ResourceError?
    func failMetadata(_ error: ResourceError?) { metadataFailure = error }
    var liveSource: PhotoSource?
    func setSource(_ source: PhotoSource) { liveSource = source }
    var files: [URL] = []
    init(_ fixture: RenderFixture) { self.fixture = fixture }
    func requestAccess() -> LibraryAccess { .full }
    func sources() -> AsyncThrowingStream<[PhotoSource], Error> { AsyncThrowingStream { $0.yield([fixture.source]); $0.finish() } }
    func source(id: SourceID) -> PhotoSource { liveSource ?? fixture.source }
    func resources(assetID: String) -> [ResourceToken] { [fixture.token] }
    func changes() -> AsyncStream<LibraryChange> { AsyncStream { $0.finish() } }
    func rawMetadata(_ resource: ResourceToken) throws -> RAWMetadata {
        metadataReads += 1
        if let metadataFailure { throw metadataFailure }
        return metadataOverride ?? fixture.raw.metadata
    }
    func materialize(_ resource: ResourceToken, progress: @escaping @Sendable (Double) -> Void) throws -> LocalResource {
        count += 1
        let file = fixture.root.appendingPathComponent("lease-\(count).RAF")
        try FileManager.default.copyItem(at: fixture.raw.fileURL, to: file); files.append(file)
        return LocalResource(token: resource, fileURL: file, checksum: fixture.raw.sha256)
    }
    nonisolated func pool(gate: SerialCameraGate = SerialCameraGate(), metadataCacheDirectory: URL? = nil) -> OriginalResourcePool {
        OriginalResourcePool(reader: self, gate: gate, metadataCacheDirectory: metadataCacheDirectory, prepare: { resource in
            PreparedRAW(fileURL: resource.fileURL, sha256: resource.checksum, sourceID: resource.token.assetID, sourceRevision: resource.token.sourceRevision, metadata: self.fixture.raw.metadata)
        })
    }
}

actor RenderCamera: CameraServing {
    func support(for expected: CameraExecutionContext) throws -> VerifiedCameraSupport {
        let current = fixture.context
        guard current == expected else { throw CameraServiceError.unsupportedContext }
        return try fixtureCameraSupport(current)
    }

    let fixture: RenderFixture
    let latch: RenderLatch?
    let contextLatch: RenderLatch?
    private var contextCalls = 0
    var calls = 0
    var resultKey: RenderKey?
    func overrideResult(_ key: RenderKey) { resultKey = key }
    var current: CameraExecutionContext
    init(_ fixture: RenderFixture, latch: RenderLatch? = nil, contextLatch: RenderLatch? = nil) {
        self.fixture = fixture; self.latch = latch; self.contextLatch = contextLatch; current = fixture.context
    }
    func states() -> AsyncStream<CameraState> { AsyncStream { $0.finish() } }
    func connect() {}
    func disconnect() {}
    func resetConnection() {}
    func importRecipes() throws -> ImportedRecipeCollection { let support=try support(for:fixture.context);return .init(recipes:[fixture.recipe],declaredSlots:support.capabilities.bankSlots,context:fixture.context,support:support) }
    func executionContext() async -> CameraExecutionContext {
        contextCalls += 1
        if contextCalls == 2, let contextLatch { await contextLatch.wait() }
        return current
    }
    func changeContext(_ value: CameraExecutionContext) { current = value }
    func render(raw: PreparedRAW, recipe: RecipeSnapshot, policy: OutputPolicy) async throws -> CameraJPEG {
        calls += 1
        if let latch { await latch.wait() }
        return try fixture.jpeg(key: resultKey ?? RenderKey(sourceID: raw.sourceID, sourceRevision: raw.sourceRevision, sourceSHA256: raw.sha256, settingsDigest: recipe.settingsDigest, cameraContext: current, width: raw.metadata.recordedGeometry.width, height: raw.metadata.recordedGeometry.height, orientation: raw.metadata.orientation, policy: policy, quality: .fullResolutionFine))
    }
}

struct ImmediateCameraScheduler: CameraWorkScheduling {
    func withPreview<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T { try await operation() }
    func withExportItem(jobID: UUID, operation: @Sendable () async throws -> CameraJPEG) async throws -> CameraJPEG { try await operation() }
    func beginExport(jobID: UUID) async throws {}
    func endExport(jobID: UUID) async {}
}

struct GatedCameraScheduler: CameraWorkScheduling {
    let gate: SerialCameraGate
    func withPreview<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T { try await gate.withExclusiveAccess(operation) }
    func withExportItem(jobID: UUID, operation: @Sendable () async throws -> CameraJPEG) async throws -> CameraJPEG { try await gate.withExclusiveAccess(operation) }
    func beginExport(jobID: UUID) async throws {}
    func endExport(jobID: UUID) async {}
}

extension RenderFixture {
    func recipe(named name: String, settingsDigest: String? = nil) -> RecipeSnapshot {
        RecipeSnapshot(id: UUID(), slot: recipe.slot, name: name, importedName: Data(name.utf8), importedSettings: recipe.importedSettings,
            settingsDigest: settingsDigest ?? recipe.settingsDigest, cameraContext: recipe.cameraContext, importedAt: Date(), renderingIssues: recipe.renderingIssues)
    }
}
