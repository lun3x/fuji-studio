import Foundation
import Testing
@testable import FujiStudio

struct ExportSuspensionTests {
    @Test func progressCarriesActualStorageFailureFromFrozenItems() async throws {
        let f = try ExportBatchFixture(), writer = ExportWriter(), engine = f.engine(writer: writer)
        await writer.rejectStorage()
        var events = await engine.events().makeAsyncIterator()
        _ = try await engine.start(sources: [f.sources[0]], recipe: f.render.recipe)
        var final: ExportEvent?
        while let event = await events.next() { if event.terminal { final = event; break } }
        #expect(final?.failures == [.insufficientStorage])
        #expect(final?.summary.completed == 0)
    }

    @Test(arguments: [false, true]) func foregroundCannotReviveAdmissionRevokedDuringPersistence(_ reopening: Bool) async throws {
        let f = try ExportBatchFixture(), barrier = RenderLatch()
        let catalog = SaveBoundaryCatalog(base: f.catalog, barrier: barrier)
        let writer = ExportWriter(), engine = f.engine(writer: writer, catalog: catalog)
        let retained = ExportJob(id: UUID(), submittedAt: Date(), recipeSnapshot: f.render.recipe,
            items: f.sources.map { ExportItem(source: $0, operationID: UUID()) }, state: .queued)
        if reopening { try await f.catalog.saveJob(retained) }
        var events = await engine.events().makeAsyncIterator()
        let admission = Task {
            if reopening { try await engine.resume(jobID: retained.id); return retained.id }
            return try await engine.start(sources: f.sources, recipe: f.render.recipe)
        }
        await barrier.entered(); await engine.suspend(); await engine.allowForegroundWork(); await barrier.release()
        let id = try await admission.value
        let first = await events.next()
        #expect(first?.terminal == true)
        #expect(first?.summary.completed == 0)
        #expect(first?.summary.unprocessed == 2)
        await engine.pause(jobID: id)
    }

    @Test func reconciliationEventsNeverClaimAnActiveWorker() async throws {
        let f = try ExportBatchFixture(), writer = ExportWriter(uncertain: true), engine = f.engine(writer: writer)
        var run = await engine.events().makeAsyncIterator()
        _ = try await engine.start(sources: f.sources, recipe: f.render.recipe)
        while let event = await run.next() { if event.terminal { break } }
        var recovery = await engine.events().makeAsyncIterator()
        try await engine.recover()
        let update = await recovery.next()
        #expect(update?.terminal == true)
        #expect(await writer.requests.count == 1)
    }

    @Test func suspensionDuringValidationRejectsAdmissionWithoutInventingAJob() async throws {
        let f = try ExportBatchFixture()
        let validation = RenderLatch()
        await f.reader.holdValidation(validation)
        let writer = ExportWriter(), engine = f.engine(writer: writer)
        let starting = Task { try await engine.start(sources: f.sources, recipe: f.render.recipe) }
        await validation.entered()
        await engine.suspend()
        await validation.release()
        await #expect(throws: ExportCoordinatorError.stopped) { try await starting.value }
        #expect(await f.camera.sources.isEmpty)
        #expect(await writer.requests.isEmpty)
        #expect(try await f.catalog.unfinishedJobs().isEmpty)
        try await engine.recover()
    }

    @Test func suspensionAfterDurableSubmissionPreservesRealFrozenJobForExplicitResume() async throws {
        let f = try ExportBatchFixture(), barrier = RenderLatch()
        let catalog = SaveBoundaryCatalog(base: f.catalog, barrier: barrier)
        let writer = ExportWriter(), engine = f.engine(writer: writer, catalog: catalog)
        var events = await engine.events().makeAsyncIterator()
        let starting = Task { try await engine.start(sources: f.sources, recipe: f.render.recipe) }
        await barrier.entered()
        await engine.suspend(); await barrier.release()
        let id = try await starting.value
        let event = await events.next()
        #expect(event?.jobID == id && event?.terminal == true)
        #expect(event?.summary.unprocessed == 2)
        #expect(await f.camera.sources.isEmpty)
        #expect(await writer.requests.isEmpty)
        #expect(try await f.catalog.job(id: id).recipeSnapshot == f.render.recipe)
        await #expect(throws: ExportCoordinatorError.stopped) { try await engine.resume(jobID: id) }
        await engine.allowForegroundWork()
        try await engine.resume(jobID: id)
        while let event = await events.next() { if event.terminal { break } }
        #expect(await writer.requests.count == 2)
    }

    @Test func suspensionAfterSaveIntentDoesNotStartPhotoKitTransaction() async throws {
        let f = try ExportBatchFixture(), barrier = RenderLatch()
        let catalog = SaveBoundaryCatalog(base: f.catalog, barrier: barrier, holdSubmission: true)
        let writer = ExportWriter(), engine = f.engine(writer: writer, catalog: catalog)
        var events = await engine.events().makeAsyncIterator()
        _ = try await engine.start(sources: f.sources, recipe: f.render.recipe)
        await barrier.entered()
        let suspension = Task { await engine.suspend() }
        while let event = await events.next() { if event.stopRequested { break } }
        await barrier.release(); await suspension.value
        #expect(await writer.requests.isEmpty)
    }
}

actor SaveBoundaryCatalog: CatalogStoring {
    let base: any CatalogStoring
    let barrier: RenderLatch
    let holdSubmission: Bool
    var held = false
    init(base: any CatalogStoring, barrier: RenderLatch, holdSubmission: Bool = false) { self.base = base; self.barrier = barrier; self.holdSubmission = holdSubmission }
    func saveJob(_ job: ExportJob) async throws {
        try await base.saveJob(job)
        let match = holdSubmission ? job.items.contains { if case .pendingSave(let pending) = $0.state, case .submitted = pending.submission { return true }; return false } : job.state == .queued
        if !held && match { held = true; await barrier.wait() }
    }
    func upsertSources(_ sources: [PhotoSource]) async throws { try await base.upsertSources(sources) }
    func replaceRecipes(_ snapshots: [RecipeSnapshot]) async throws { try await base.replaceRecipes(snapshots) }
    func recipes(camera: CameraExecutionContext) async throws -> [RecipeSnapshot] { try await base.recipes(camera: camera) }
    func latestRecipes() async throws -> [RecipeSnapshot] { try await base.latestRecipes() }
    func versions(sourceID: SourceID) async throws -> [SavedVersion] { try await base.versions(sourceID: sourceID) }
    func job(id: UUID) async throws -> ExportJob { try await base.job(id: id) }
    func unfinishedJobs() async throws -> [ExportJob] { try await base.unfinishedJobs() }
    func confirmSaved(jobID: UUID, operationID: UUID, version: SavedVersion) async throws { try await base.confirmSaved(jobID: jobID, operationID: operationID, version: version) }
    func setAvailability(assetID: String, availability: AssetAvailability) async throws { try await base.setAvailability(assetID: assetID, availability: availability) }
}
