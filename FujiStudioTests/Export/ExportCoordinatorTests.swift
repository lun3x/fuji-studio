@testable import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

// These unique roots contain live SwiftData stores. Retain them for test-process/OS
// cleanup: no public all-container close barrier makes in-test recursive unlink safe.
struct ExportCoordinatorTests {
    @Test(arguments: [false, true])
    func stalePinnedExportRerendersOnlyWhenSaveWasNeverSubmitted(_ submitted: Bool) async throws {
        let f = try RenderFixture()
        let catalog = try SwiftDataCatalog(storeURL: f.root.appendingPathComponent("catalog.store"))
        let cache = try f.cache(), reader = RenderLibrary(f), writer = ExportWriter(), camera = RenderCamera(f)
        let oldContext = CameraExecutionContext(
            model: f.context.model, firmware: f.context.firmware, capability: f.context.capability,
            supportVersion: "xt5-4.31-0200-structured-frame-v4",
            sessionIdentity: f.context.sessionIdentity, generation: f.context.generation)
        let oldJPEG = try f.jpeg(key: f.key(context: oldContext))
        try await cache.store(oldJPEG, key: oldJPEG.key)
        let pinned = oldJPEG.relocated(to: try await cache.pin(oldJPEG.key))
        let operationID = UUID()
        let pending = PendingSave(operationID: operationID, jpeg: pinned,
            submission: submitted ? .unknown(at: Date()) : .notSubmitted)
        let job = ExportJob(id: UUID(), submittedAt: Date(), recipeSnapshot: f.recipe,
            items: [ExportItem(source: f.source, operationID: operationID, state: .pendingSave(pending))], state: .paused)
        try await catalog.saveJob(job)
        let engine = ExportCoordinator(reader: reader, camera: camera, catalog: catalog, writer: writer,
            pool: reader.pool(), cache: cache, scheduler: CameraWorkScheduler())
        var events = await engine.events().makeAsyncIterator()
        try await engine.resume(jobID: job.id)
        _ = await terminal(&events, job.id)
        if submitted {
            #expect(await camera.calls == 0)
            #expect(await writer.requests.isEmpty)
            #expect(await cache.lookup(oldJPEG.key) != nil)
            guard case .unresolved = try await catalog.job(id: job.id).items[0].state else {
                Issue.record("An uncertain Photos transaction must remain reconciliable")
                return
            }
        } else {
            #expect(await camera.calls == 1)
            #expect(await writer.requests.count == 1)
            #expect(await writer.requests.first?.jpeg.cameraContext.supportVersion == XT5WorkingProfile.supportVersion)
            #expect(await writer.requests.first?.operationID == operationID)
            #expect(try await catalog.job(id: job.id).state == .saved)
            #expect(await cache.lookup(oldJPEG.key) == nil)
        }
    }

    @Test func renamedCacheUsesChosenSnapshotAndDistinctPhotosOperation() async throws {
        let f = try RenderFixture()
        let catalog = try SwiftDataCatalog(storeURL: f.root.appendingPathComponent("catalog.store"))
        let cache = try f.cache(), reader = RenderLibrary(f), writer = ExportWriter(), camera = RenderCamera(f)
        let jpeg = try f.jpeg(); try await cache.store(jpeg, key: jpeg.key)
        let engine = ExportCoordinator(reader: reader, camera: camera, catalog: catalog, writer: writer,
            pool: reader.pool(), cache: cache, scheduler: CameraWorkScheduler())
        var events = await engine.events().makeAsyncIterator()
        let chosen = f.recipe(named: "Chosen C3")
        let id = try await engine.start(sources: [f.source], recipe: chosen)
        while let event = await events.next() { if event.jobID == id && event.terminal { break } }
        let reopened = try SwiftDataCatalog(storeURL: f.root.appendingPathComponent("catalog.store"))
        let versions = try await reopened.versions(sourceID: f.source.id)
        #expect(versions.count == 1)
        #expect(versions.first?.recipeSnapshot == chosen)
        #expect(versions.first?.jpeg.recipeSnapshotID == jpeg.recipeSnapshotID)
        #expect(versions.first?.operationID != jpeg.operationID)
        #expect(await camera.calls == 0)
        #expect(await writer.requests.count == 1)
    }

    @Test func uncertainEmptyLookupNeverResubmitsAcrossReopen() async throws {
        let f = try RenderFixture()
        let url = f.root.appendingPathComponent("catalog.store"), cache = try f.cache(), reader = RenderLibrary(f)
        let writer = ExportWriter(uncertain: true), catalog = try SwiftDataCatalog(storeURL: url)
        let engine = ExportCoordinator(reader: reader, camera: RenderCamera(f), catalog: catalog, writer: writer,
            pool: reader.pool(), cache: cache, scheduler: CameraWorkScheduler())
        var events = await engine.events().makeAsyncIterator()
        let id = try await engine.start(sources: [f.source], recipe: f.recipe)
        while let event = await events.next() { if event.jobID == id && event.terminal { break } }
        let reopened = try SwiftDataCatalog(storeURL: url)
        let recovery = ExportCoordinator(reader: reader, camera: RenderCamera(f), catalog: reopened, writer: writer,
            pool: reader.pool(), cache: cache, scheduler: CameraWorkScheduler())
        try await recovery.recover(); try await recovery.retry(jobID: id)
        await recovery.pause(jobID: id)
        #expect(await writer.requests.count == 1)
        guard case .unresolved(let pending) = try await reopened.job(id: id).items[0].state else {
            Issue.record("Unknown save was discarded"); return
        }
        #expect(pending.placeholderID == "synthetic-asset")
        #expect(FileManager.default.fileExists(atPath: pending.jpeg.fileURL.path))
        await writer.resolve(pending.operationID)
        try await recovery.recover()
        #expect(try await reopened.versions(sourceID: f.source.id).count == 1)
        #expect(await writer.requests.count == 1)
    }
}

actor ExportWriter: PhotoLibraryWriting {
    var requests: [PhotoSaveRequest] = []
    var uncertain: Bool
    var reject = false
    var storageRejection = false
    func rejectStorage() { storageRejection = true }
    func rejectNext() { reject = true }
    func succeed() { uncertain = false }
    var found: UUID?
    let latch: RenderLatch?
    init(uncertain: Bool = false, latch: RenderLatch? = nil) { self.uncertain = uncertain; self.latch = latch }
    func saveJPEG(_ request: PhotoSaveRequest, onPlaceholder: @escaping @Sendable (String) -> Void) async throws -> SavedAsset {
        requests.append(request); onPlaceholder("synthetic-asset")
        if let latch { await latch.wait() }
        if storageRejection { storageRejection = false; throw PhotoLibraryWriteError.rejected(.insufficientStorage) }
        if reject { reject = false; throw PhotoLibraryWriteError.rejected(.invalidResource) }
        if uncertain { throw PhotoLibraryWriteError.uncertain(.missingConfirmation) }
        return SavedAsset(assetID: "synthetic-asset", operationID: request.operationID, photosGeometry: nil)
    }
    func resolve(_ operation: UUID) { found = operation }
    func findExport(operationID: UUID, knownAssetID: String?) -> SaveLookup {
        if found == operationID { return .found(.init(assetID: "synthetic-asset", operationID: operationID, photosGeometry: nil)) }
        return .notFound
    }
}

extension ExportCoordinatorTests {
    @Test func cancellationDrainsSubmittedPhotosAndStartsNoNextItem() async throws {
        let f = try ExportBatchFixture()
        let latch = RenderLatch(), writer = ExportWriter(latch: latch), engine = f.engine(writer: writer)
        var events = await engine.events().makeAsyncIterator()
        let id = try await engine.start(sources: f.sources, recipe: f.render.recipe)
        await latch.entered()
        let cancelling = Task { await engine.cancel(jobID: id) }
        while let event = await events.next() { if event.stopRequested { break } }
        #expect(await writer.requests.count == 1)
        #expect(try await f.catalog.versions(sourceID: f.sources[0].id).isEmpty)
        await latch.release(); await cancelling.value
        _ = await terminal(&events, id)
        let job = try await f.catalog.job(id: id)
        guard case .saved = job.items[0].state else { Issue.record("Active save abandoned"); return }
        #expect(job.items[1].state == .cancelled)
        #expect(await writer.requests.count == 1)
        #expect(await f.scheduler.exportJobID == nil)
        try await engine.retry(jobID: id)
        _ = await terminal(&events, id)
        #expect(await writer.requests.count == 2) // Confirmed first item is excluded.
    }

    @Test func lifecyclePausePreservesQueuedItemsAndResumeUsesFrozenRecipe() async throws {
        let f = try ExportBatchFixture()
        let latch = RenderLatch(), writer = ExportWriter(latch: latch), engine = f.engine(writer: writer)
        var events = await engine.events().makeAsyncIterator()
        let id = try await engine.start(sources: f.sources, recipe: f.render.recipe)
        await latch.entered()
        let pausing = Task { await engine.pause(jobID: id) }
        while let event = await events.next() { if event.stopRequested { break } }
        await latch.release(); await pausing.value
        _ = await terminal(&events, id)
        let paused = try await f.catalog.job(id: id)
        #expect(paused.state == .paused)
        #expect(paused.items[1].state == .queued)
        // Refreshing the source metadata and recipe collection cannot change submitted labels/date.
        await f.reader.changeCaptureDate()
        try await f.catalog.replaceRecipes(fixtureCollection(f.refreshedRecipes()))
        try await engine.resume(jobID: id)
        let final = await terminal(&events, id)
        #expect(final?.summary.completed == 2)
        #expect(await f.camera.recipes == [f.render.recipe.id, f.render.recipe.id])
        #expect(await writer.requests.map(\.captureDate) == [Date(timeIntervalSince1970: 10), Date(timeIntervalSince1970: 10)])
        #expect(await f.reader.maxLiveFiles == 1)
    }

    @Test func badRAFContinuesButDisconnectPausesAndResumeReattemptsFrozenItem() async throws {
        for sessionFailure in [false, true] {
            let f = try ExportBatchFixture()
            await f.camera.failFirst(sessionFailure ? .notReady : .unsupportedSource)
            let writer = ExportWriter(), engine = f.engine(writer: writer)
            var events = await engine.events().makeAsyncIterator()
            let id = try await engine.start(sources: f.sources, recipe: f.render.recipe)
            let final = await terminal(&events, id)
            #expect(await f.scheduler.exportJobID == nil)
            if sessionFailure {
                #expect(final?.stage == .paused)
                #expect(await writer.requests.isEmpty)
                try await engine.resume(jobID: id)
                let resumed = await terminal(&events, id)
                #expect(resumed?.summary.completed == 2)
            } else {
                #expect(final?.summary.failed == 1)
                #expect(final?.summary.completed == 1)
                #expect(await writer.requests.map(\.jpeg.sourceID) == ["standalone"])
            }
        }
    }

    @Test func changedResourcesAreItemFailureAndNeverSilentlyRetargeted() async throws {
        let f = try ExportBatchFixture()
        let latch = RenderLatch(), writer = ExportWriter(latch: latch), engine = f.engine(writer: writer)
        var events = await engine.events().makeAsyncIterator()
        let id = try await engine.start(sources: f.sources, recipe: f.render.recipe)
        await latch.entered(); await f.reader.changeResource()
        await latch.release()
        let final = await terminal(&events, id)
        #expect(final?.summary.failed == 1)
        #expect(final?.summary.completed == 1)
        #expect(await f.camera.sources == ["paired"])
    }

    @Test func admissionIsReservedBeforeValidationAwaitAndInvalidSourcesNeverCreateJob() async throws {
        let f = try ExportBatchFixture()
        let latch = RenderLatch(); await f.reader.holdValidation(latch)
        let engine = f.engine(writer: ExportWriter())
        let starting = Task { try await engine.start(sources: f.sources, recipe: f.render.recipe) }
        await latch.entered()
        await #expect(throws: ExportCoordinatorError.alreadyActive) {
            try await engine.start(sources: f.sources, recipe: f.render.recipe)
        }
        await #expect(throws: ExportCoordinatorError.alreadyActive) { try await engine.recover() }
        await latch.release()
        let id = try await starting.value
        await engine.cancel(jobID: id)
        #expect(try await f.catalog.unfinishedJobs().map(\.id) == [id])
        await #expect(throws: ExportCoordinatorError.invalidSubmission) {
            try await engine.start(sources: [], recipe: f.render.recipe)
        }
    }

    @Test(arguments: [CrashBoundary.beforeIntent, .afterPlaceholder, .afterSuccess, .afterConfirmation])
    func recoveryUsesDurableKnowledgeAcrossEverySaveBoundary(_ boundary: CrashBoundary) async throws {
        let f = try ExportBatchFixture()
        let fault = FaultCatalog(base: f.catalog, boundary: boundary)
        let writer = ExportWriter(uncertain: boundary == .afterPlaceholder)
        let engine = f.engine(writer: writer, catalog: fault)
        var events = await engine.events().makeAsyncIterator()
        let id = try await engine.start(sources: [f.sources[0]], recipe: f.render.recipe)
        _ = await terminal(&events, id)
        let reopened = try SwiftDataCatalog(storeURL: f.storeURL)
        let recovery = f.engine(writer: writer, catalog: reopened)
        try await recovery.recover()
        if boundary == .beforeIntent {
            #expect(await writer.requests.isEmpty)
            var recoveredEvents = await recovery.events().makeAsyncIterator()
            try await recovery.resume(jobID: id); _ = await terminal(&recoveredEvents, id)
        } else {
            #expect(await writer.requests.count == 1)
            let item = try await reopened.job(id: id).items[0]
            if boundary != .afterConfirmation {
                guard case .unresolved(let p) = item.state else { Issue.record("Lost uncertain transaction"); return }
                #expect(FileManager.default.fileExists(atPath: p.jpeg.fileURL.path))
                #expect(p.placeholderID == "synthetic-asset")
                await writer.resolve(item.operationID)
                try await recovery.recover()
            }
        }
        #expect(try await reopened.versions(sourceID: "paired").count == 1)
        #expect(await writer.requests.count == 1)
        // Confirmation and repeated recovery cannot create a second version or save.
        try await recovery.recover()
        #expect(try await reopened.versions(sourceID: "paired").count == 1)
    }

    @Test func anotherSuccessfulJobCannotUnpinUnknownJobsSharedPixels() async throws {
        let f = try ExportBatchFixture()
        let writer = ExportWriter(uncertain: true), engine = f.engine(writer: writer)
        var events = await engine.events().makeAsyncIterator()
        let first = try await engine.start(sources: [f.sources[0]], recipe: f.render.recipe)
        _ = await terminal(&events, first)
        guard case .unresolved(let pending) = try await f.catalog.job(id: first).items[0].state else {
            Issue.record("Expected uncertain save"); return
        }
        let success = f.engine(writer: ExportWriter())
        var successEvents = await success.events().makeAsyncIterator()
        let second = try await success.start(sources: [f.sources[0]], recipe: f.render.recipe(named: "new label"))
        _ = await terminal(&successEvents, second)
        try await success.recover()
        #expect(FileManager.default.fileExists(atPath: pending.jpeg.fileURL.path))
        #expect(await f.cache.lookup(pending.jpeg.key) != nil)
        #expect(await f.camera.sources == ["paired"])
        #expect(try await f.catalog.versions(sourceID: "paired").first?.recipeSnapshot.name == "new label")
    }

    private func terminal(_ events: inout AsyncStream<ExportEvent>.AsyncIterator, _ id: UUID) async -> ExportEvent? {
        while let event = await events.next() { if event.jobID == id && event.terminal { return event } }
        return nil
    }
}

enum CrashBoundary: Sendable { case beforeIntent, afterIntent, afterPlaceholder, afterSuccess, afterConfirmation, enumerationFailure, readsUnavailable }

private actor FaultCatalog: CatalogStoring {
    let base: SwiftDataCatalog, boundary: CrashBoundary
    var fired = false
    var enumerations = 0
    init(base: SwiftDataCatalog, boundary: CrashBoundary) { self.base = base; self.boundary = boundary }
    func upsertSources(_ sources: [PhotoSource]) async throws { try await base.upsertSources(sources) }
    func replaceRecipes(_ snapshots: ImportedRecipeCollection) async throws { try await base.replaceRecipes(snapshots) }
    func latestRecipeSlots() async throws -> [RecipeSlot] { try await base.latestRecipeSlots() }
    func recipes(camera: CameraExecutionContext) async throws -> [RecipeSnapshot] { try await base.recipes(camera: camera) }
    func latestRecipes() async throws -> [RecipeSnapshot] { try await base.latestRecipes() }
    func updatePhoneRecipe(_ draft: PhoneRecipeDraft) async throws -> PhoneRecipe { try await base.updatePhoneRecipe(draft) }
    func phoneRecipes() async throws -> [PhoneRecipe] { try await base.phoneRecipes() }
    func copyRecipeToPhone(_ recipe: RecipeSnapshot) async throws -> PhoneRecipe { try await base.copyRecipeToPhone(recipe) }
    func deletePhoneRecipe(id: UUID) async throws { try await base.deletePhoneRecipe(id: id) }
    func versions(sourceID: SourceID) async throws -> [SavedVersion] { try await base.versions(sourceID: sourceID) }
    func saveJob(_ job: ExportJob) async throws {
        if !fired, boundary == .beforeIntent,
           job.items.contains(where: { if case .pendingSave(let p) = $0.state, case .submitted = p.submission { true } else { false } }) {
            fired = true; throw CatalogError.durableFailure("synthetic crash before intent")
        }
        try await base.saveJob(job)
        if !fired, boundary == .afterIntent,
           job.items.contains(where: { if case .pendingSave(let p) = $0.state, case .submitted = p.submission { true } else { false } }) {
            fired = true; throw CatalogError.durableFailure("synthetic crash after intent")
        }
    }
    func job(id: UUID) async throws -> ExportJob {
        if boundary == .readsUnavailable { throw CatalogError.durableFailure("synthetic unreadable journal") }
        return try await base.job(id: id)
    }
    func unfinishedJobs() async throws -> [ExportJob] {
        enumerations += 1
        if boundary == .enumerationFailure, enumerations == 2 { throw CatalogError.durableFailure("synthetic reference enumeration failure") }
        return try await base.unfinishedJobs()
    }
    func confirmSaved(jobID: UUID, operationID: UUID, version: SavedVersion) async throws {
        let job = try await base.job(id: jobID)
        let p: PendingSave
        switch job.items[0].state {
        case .pendingSave(let value), .unresolved(let value): p = value
        default: throw CatalogError.invalidState("Expected pending confirmation")
        }
        guard p.placeholderID == version.outputAssetID else {
            throw CatalogError.invalidState("Confirmation raced placeholder persistence")
        }
        if !fired, boundary == .afterSuccess { fired = true; throw CatalogError.durableFailure("synthetic crash after Photos success") }
        try await base.confirmSaved(jobID: jobID, operationID: operationID, version: version)
        if !fired, boundary == .afterConfirmation { fired = true; throw CatalogError.durableFailure("synthetic crash after confirmation") }
    }
    func setAvailability(assetID: String, availability: AssetAvailability) async throws { try await base.setAvailability(assetID: assetID, availability: availability) }
}

struct ExportBatchFixture {
    let render: RenderFixture, reader: BatchReader, camera: BatchCamera, cache: FileRenderCache
    let catalog: SwiftDataCatalog, scheduler = CameraWorkScheduler()
    var storeURL: URL { render.root.appendingPathComponent("catalog.store") }
    let sources: [PhotoSource]
    init() throws {
        render = try RenderFixture()
        sources = ["paired", "standalone"].map { id in
            let raf = ResourceToken(assetID: id, role: .primaryOriginal, contentTypeIdentifier: "com.fuji.raw-image", format: .raf, originalFilename: "synthetic.RAF", discriminator: "raw", sourceRevision: "v1")
            let jpeg = ResourceToken(assetID: id, role: .alternateOriginal, contentTypeIdentifier: "public.jpeg", format: .jpeg, originalFilename: "synthetic.JPG", discriminator: "jpeg", sourceRevision: "v1")
            return PhotoSource(id: id, originalResources: .init(raf: raf, jpeg: id == "paired" ? jpeg : nil), captureDate: Date(timeIntervalSince1970: 10), location: .init(latitude: 1, longitude: 2, altitude: 3), resourceRevision: "v1")
        }
        reader = BatchReader(render, sources: sources); camera = BatchCamera(render)
        cache = try render.cache(); catalog = try SwiftDataCatalog(storeURL: render.root.appendingPathComponent("catalog.store"))
    }
    func engine(writer: any PhotoLibraryWriting, catalog: (any CatalogStoring)? = nil) -> ExportCoordinator {
        ExportCoordinator(reader: reader, camera: camera, catalog: catalog ?? self.catalog, writer: writer,
            pool: reader.pool(), cache: cache, scheduler: scheduler)
    }
    func refreshedRecipes() -> [RecipeSnapshot] {
        (1...7).map { slot in
            RecipeSnapshot(id: UUID(), slot: slot, name: "refreshed", importedName: render.recipe.importedName,
                importedSettings: render.recipe.importedSettings, settingsDigest: render.recipe.settingsDigest,
                cameraContext: render.recipe.cameraContext, importedAt: Date(), renderingIssues: [])
        }
    }
}

actor BatchReader: PhotoLibraryReading {
    let fixture: RenderFixture
    var live: [PhotoSource], files: [URL] = []
    var maxLiveFiles = 0
    var validationLatch: RenderLatch?
    init(_ fixture: RenderFixture, sources: [PhotoSource]) { self.fixture = fixture; live = sources }
    func holdValidation(_ latch: RenderLatch) { validationLatch = latch }
    func requestAccess() -> LibraryAccess { .full }
    func sources() -> AsyncThrowingStream<[PhotoSource], Error> { AsyncThrowingStream { $0.yield(live); $0.finish() } }
    func source(id: SourceID) async throws -> PhotoSource {
        if let latch = validationLatch { await latch.wait() }
        guard let source = live.first(where: { $0.id == id }) else { throw ResourceError.inaccessibleAsset(id) }
        return source
    }
    func resources(assetID: String) -> [ResourceToken] { live.filter { $0.id == assetID }.map(\.originalResources.raf) }
    func changes() -> AsyncStream<LibraryChange> { AsyncStream { $0.finish() } }
    func rawMetadata(_ resource: ResourceToken) throws -> RAWMetadata { throw ResourceError.invalidRAF("Metadata is unavailable in this fixture") }
    func materialize(_ resource: ResourceToken, progress: @escaping @Sendable (Double) -> Void) throws -> LocalResource {
        let file = fixture.root.appendingPathComponent(UUID().uuidString + ".RAF")
        try FileManager.default.copyItem(at: fixture.raw.fileURL, to: file); files.append(file)
        maxLiveFiles = max(maxLiveFiles, files.filter { FileManager.default.fileExists(atPath: $0.path) }.count)
        return LocalResource(token: resource, fileURL: file, checksum: fixture.raw.sha256)
    }
    func changeCaptureDate() {
        live = live.map { PhotoSource(id: $0.id, originalResources: $0.originalResources, captureDate: Date(timeIntervalSince1970: 99), location: nil, resourceRevision: $0.resourceRevision) }
    }
    func changeResource() {
        let old = live[1]
        live[1] = PhotoSource(id: old.id, originalResources: old.originalResources, captureDate: nil, location: nil, resourceRevision: "different")
    }
    nonisolated func pool() -> OriginalResourcePool {
        OriginalResourcePool(reader: self, prepare: { resource in
            PreparedRAW(fileURL: resource.fileURL, sha256: resource.checksum, sourceID: resource.token.assetID,
                sourceRevision: resource.token.sourceRevision, metadata: self.fixture.raw.metadata)
        })
    }
}

actor BatchCamera: CameraServing {
    func support(for expected: CameraExecutionContext) throws -> VerifiedCameraSupport {
        let current = fixture.context
        guard current == expected else { throw CameraServiceError.unsupportedContext }
        return try fixtureCameraSupport(current)
    }

    let fixture: RenderFixture
    var sources: [SourceID] = [], recipes: [UUID] = []
    var firstError: CameraServiceError?
    var latch: RenderLatch?
    func hold(_ latch: RenderLatch) { self.latch = latch }
    init(_ fixture: RenderFixture) { self.fixture = fixture }
    func failFirst(_ error: CameraServiceError) { firstError = error }
    func executionContext() -> CameraExecutionContext { fixture.context }
    func states() -> AsyncStream<CameraState> { AsyncStream { $0.finish() } }
    func connect() {}
    func importRecipes() throws -> ImportedRecipeCollection { throw CameraServiceError.unsupportedContext }
    func disconnect() {}
    func resetConnection() {}
    func render(raw: PreparedRAW, recipe: RecipeSnapshot, policy: OutputPolicy) async throws -> CameraJPEG {
        sources.append(raw.sourceID); recipes.append(recipe.id)
        if let latch { await latch.wait() }
        if let error = firstError { firstError = nil; throw error }
        return try fixture.jpeg(key: RenderKey(sourceID: raw.sourceID, sourceRevision: raw.sourceRevision, sourceSHA256: raw.sha256,
            settingsDigest: recipe.settingsDigest, cameraContext: fixture.context, width: raw.metadata.recordedGeometry.width,
            height: raw.metadata.recordedGeometry.height, orientation: raw.metadata.orientation, policy: policy, quality: .fullResolutionFine))
    }
}

extension ExportCoordinatorTests {
    @Test func cancelPausedJobClassifiesRemainingItemsWithoutSaving() async throws {
        let f = try ExportBatchFixture()
        await f.camera.failFirst(.notReady)
        let writer = ExportWriter(), engine = f.engine(writer: writer)
        var events = await engine.events().makeAsyncIterator()
        let id = try await engine.start(sources: f.sources, recipe: f.render.recipe)
        _ = await terminal(&events, id)
        await engine.cancel(jobID: id)
        #expect(try await f.catalog.job(id: id).state == .cancelled)
        #expect(try await f.catalog.job(id: id).items.allSatisfy { $0.state == .cancelled })
        #expect(await writer.requests.isEmpty)
    }

    @Test func crashAfterIntentBeforeCallIsConservativelyUnknown() async throws {
        let f = try ExportBatchFixture()
        let fault = FaultCatalog(base: f.catalog, boundary: .afterIntent), writer = ExportWriter()
        let engine = f.engine(writer: writer, catalog: fault)
        var events = await engine.events().makeAsyncIterator()
        let id = try await engine.start(sources: [f.sources[0]], recipe: f.render.recipe)
        _ = await terminal(&events, id)
        let reopened = try SwiftDataCatalog(storeURL: f.storeURL), recovery = f.engine(writer: writer, catalog: try SwiftDataCatalog(storeURL: f.storeURL))
        try await recovery.recover()
        var recoveredEvents = await recovery.events().makeAsyncIterator()
        try await recovery.retry(jobID: id); _ = await terminal(&recoveredEvents, id)
        #expect(await writer.requests.isEmpty)
        guard case .unresolved(let pending) = try await reopened.job(id: id).items[0].state else {
            Issue.record("Submitted intent was treated as safe absence"); return
        }
        #expect(pending.placeholderID == nil)
        #expect(FileManager.default.fileExists(atPath: pending.jpeg.fileURL.path))
    }

    @Test func protectedPinConflictDoesNotDeleteAnotherJobsRecoveryFile() async throws {
        let f = try ExportBatchFixture()
        let writer = ExportWriter(uncertain: true), engine = f.engine(writer: writer)
        var events = await engine.events().makeAsyncIterator()
        let first = try await engine.start(sources: [f.sources[0]], recipe: f.render.recipe)
        _ = await terminal(&events, first)
        guard case .unresolved(let pending) = try await f.catalog.job(id: first).items[0].state else { Issue.record("Expected unknown"); return }
        try Data([1, 2, 3]).write(to: pending.jpeg.fileURL)
        let second = try await engine.start(sources: [f.sources[0]], recipe: f.render.recipe)
        let final = await terminal(&events, second)
        #expect(final?.summary.failed == 1)
        #expect(await writer.requests.count == 1)
        #expect(try Data(contentsOf: pending.jpeg.fileURL) == Data([1, 2, 3]))
        #expect(try await f.catalog.job(id: first).items[0].state == .unresolved(pending))
    }

    @Test func definitiveNativeRejectionAllowsOnlyExplicitRetry() async throws {
        let f = try ExportBatchFixture()
        let writer = ExportWriter(), engine = f.engine(writer: writer)
        await writer.rejectNext()
        var events = await engine.events().makeAsyncIterator()
        let id = try await engine.start(sources: [f.sources[0]], recipe: f.render.recipe)
        let final = await terminal(&events, id)
        #expect(final?.summary.failed == 1)
        #expect(await writer.requests.count == 1)
        try await engine.recover()
        _ = await terminal(&events, id) // Recovery now publishes this retryable terminal job.
        #expect(await writer.requests.count == 1)
        try await engine.retry(jobID: id); _ = await terminal(&events, id)
        #expect(await writer.requests.count == 2)
        #expect(try await f.catalog.versions(sourceID: "paired").count == 1)
        let requests = await writer.requests
        #expect(try #require(requests.first).operationID == #require(requests.last).operationID)
    }
}

extension ExportCoordinatorTests {
    @Test func retrySkipsUnknownButStillProcessesRemainingQueuedItem() async throws {
        let f = try ExportBatchFixture()
        let writer = ExportWriter(uncertain: true), engine = f.engine(writer: writer)
        var events = await engine.events().makeAsyncIterator()
        let id = try await engine.start(sources: f.sources, recipe: f.render.recipe)
        _ = await terminal(&events, id)
        await writer.succeed()
        try await engine.retry(jobID: id)
        let final = await terminal(&events, id)
        #expect(final?.summary.completed == 1)
        #expect(final?.summary.unresolved == 1)
        #expect(await writer.requests.map(\.jpeg.sourceID) == ["paired", "standalone"])
        #expect(try await f.catalog.versions(sourceID: "paired").isEmpty)
        #expect(try await f.catalog.versions(sourceID: "standalone").count == 1)
    }
}

extension ExportCoordinatorTests {
    @Test func recoveryReclaimsConfirmedOrphanButPreservesUnindexedReservations() async throws {
        let f = try ExportBatchFixture()
        let fault = FaultCatalog(base: f.catalog, boundary: .afterConfirmation), writer = ExportWriter()
        let engine = f.engine(writer: writer, catalog: fault)
        var events = await engine.events().makeAsyncIterator()
        let id = try await engine.start(sources: [f.sources[0]], recipe: f.render.recipe)
        _ = await terminal(&events, id)
        let pinned = try #require(await writer.requests.first?.jpeg.fileURL)
        #expect(FileManager.default.fileExists(atPath: pinned.path))
        let unknown = f.render.root.appendingPathComponent("support/unindexed-reservation")
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        try Data([7, 8]).write(to: unknown.appendingPathComponent("image.JPG"))
        let reopened = try SwiftDataCatalog(storeURL: f.storeURL)
        let recovery = ExportCoordinator(reader: f.reader, camera: f.camera, catalog: reopened, writer: writer,
            pool: f.reader.pool(), cache: try f.render.cache(), scheduler: f.scheduler)
        try await recovery.recover()
        #expect(!FileManager.default.fileExists(atPath: pinned.path))
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        #expect(try await reopened.versions(sourceID: "paired").count == 1)
        #expect(await writer.requests.count == 1)
    }
}

extension ExportCoordinatorTests {
    @Test func cancellationDrainsCameraWithoutSubmittingPhotosOrNextRAW() async throws {
        let f = try ExportBatchFixture()
        let latch = RenderLatch(); await f.camera.hold(latch)
        let writer = ExportWriter(), engine = f.engine(writer: writer)
        var events = await engine.events().makeAsyncIterator()
        let id = try await engine.start(sources: f.sources, recipe: f.render.recipe)
        await latch.entered()
        let cancelling = Task { await engine.cancel(jobID: id) }
        while let event = await events.next() { if event.stopRequested { break } }
        #expect(await f.camera.sources == ["paired"])
        #expect(await writer.requests.isEmpty)
        await latch.release(); await cancelling.value
        #expect(try await f.catalog.job(id: id).items.allSatisfy { $0.state == .cancelled })
        #expect(await writer.requests.isEmpty)
        #expect(await f.scheduler.exportJobID == nil)
    }

    @Test func nativeStorageRejectionRetainsActionableFailureType() async throws {
        let f = try ExportBatchFixture()
        let writer = ExportWriter(), engine = f.engine(writer: writer)
        await writer.rejectStorage()
        var events = await engine.events().makeAsyncIterator()
        let id = try await engine.start(sources: [f.sources[0]], recipe: f.render.recipe)
        _ = await terminal(&events, id)
        #expect(try await f.catalog.job(id: id).items[0].state == .failed(.insufficientStorage))
        #expect(await writer.requests.count == 1)
    }
}

extension ExportCoordinatorTests {
    @Test func failedCompleteReferenceEnumerationReleasesNoPins() async throws {
        let f = try ExportBatchFixture()
        let writer = ExportWriter(uncertain: true), engine = f.engine(writer: writer)
        var events = await engine.events().makeAsyncIterator()
        let id = try await engine.start(sources: [f.sources[0]], recipe: f.render.recipe)
        _ = await terminal(&events, id)
        guard case .unresolved(let pending) = try await f.catalog.job(id: id).items[0].state else { Issue.record("Expected pending"); return }
        await writer.resolve(pending.operationID)
        let fault = FaultCatalog(base: f.catalog, boundary: .enumerationFailure)
        let recovery = f.engine(writer: writer, catalog: fault)
        await #expect(throws: CatalogError.self) { try await recovery.recover() }
        #expect(FileManager.default.fileExists(atPath: pending.jpeg.fileURL.path))
        #expect(try await f.catalog.versions(sourceID: "paired").count == 1)
        try await engine.recover()
        #expect(!FileManager.default.fileExists(atPath: pending.jpeg.fileURL.path))
    }
}

extension ExportCoordinatorTests {
    @Test func unreadableJournalStillEmitsTerminalPersistenceFailureAndReleasesPriority() async throws {
        let f = try ExportBatchFixture()
        let fault = FaultCatalog(base: f.catalog, boundary: .readsUnavailable), writer = ExportWriter()
        let engine = f.engine(writer: writer, catalog: fault)
        let events = await engine.events()
        let id = try await engine.start(sources: [f.sources[0]], recipe: f.render.recipe)
        let event = await withTaskGroup(of: ExportEvent?.self) { group in
            group.addTask { for await event in events { if event.terminal { return event } }; return nil }
            group.addTask { try? await Task.sleep(for: .seconds(1)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll(); return first
        }
        #expect(event?.jobID == id)
        guard case .persistence = event?.pauseReason else { Issue.record("Missing persistence failure event"); return }
        #expect(await f.scheduler.exportJobID == nil)
        #expect(await writer.requests.isEmpty)
    }
}
