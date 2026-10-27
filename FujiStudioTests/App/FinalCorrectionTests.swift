import SwiftUI
import Testing
@testable import FujiStudio

@MainActor struct FinalCorrectionTests {
    // Catches terminal-only jobs falling out of the disk query used by a fresh model.
    @Test(arguments: [false, true]) func reopenedTerminalJobRetainsFrozenSummaryAndRetriesOnlyRemaining(_ cancelled: Bool) async throws {
        let f = try await FixtureEnvironment.make()
        let original = try #require(f.environment.catalog as? SwiftDataCatalog)
        let source = try await f.reader.source(id: "source-0"), remaining = try await f.reader.source(id: "source-2")
        let recipe = try #require(try await original.latestRecipes().first)
        let savedID = UUID(), savedOperation = UUID(), remainingOperation = UUID()
        var first = ExportItem(source: source, operationID: savedOperation)
        await f.camera.connect()
        let local = try await f.reader.materialize(source.originalResources.raf, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: local.fileURL) }
        let jpeg = try await f.camera.render(raw: Self.prepare(local), recipe: recipe, policy: .fullSizeFineRecordedGeometry)
        let at = Date()
        first.state = .pendingSave(PendingSave(operationID: savedOperation, jpeg: jpeg, submission: .submitted(at: at)))
        var second = ExportItem(source: remaining, operationID: remainingOperation)
        second.state = cancelled ? .cancelled : .failed(.insufficientStorage)
        let job = ExportJob(id: UUID(), submittedAt: Date(), recipeSnapshot: recipe, items: [first, second], state: cancelled ? .cancelled : .failed)
        let doneOperation = UUID()
        let done = ExportJob(id: UUID(), submittedAt: Date(), recipeSnapshot: recipe,
            items: [ExportItem(source: source, operationID: doneOperation, state: .pendingSave(PendingSave(operationID: doneOperation, jpeg: jpeg, submission: .submitted(at: at))))], state: .pendingSave)
        try await original.saveJob(job); try await original.saveJob(done)
        for (id, operation, version) in [(job.id, savedOperation, savedID), (done.id, doneOperation, UUID())] {
            try await original.confirmSaved(jobID: id, operationID: operation, version: SavedVersion(id: version,
                sourceID: source.id, outputAssetID: "synthetic-\(operation)", recipeSnapshot: recipe,
                operationID: operation, exportedAt: at, jpeg: jpeg, availability: .available))
        }
        let reopened = try SwiftDataCatalog(storeURL: try #require(original.modelContainer.configurations.first?.url))
        let scheduler = CameraWorkScheduler(), pool = OriginalResourcePool(reader: f.reader, prepare: Self.prepare)
        let exports = ExportCoordinator(reader: f.reader, camera: f.camera, catalog: reopened, writer: f.writer,
            pool: pool, cache: f.environment.cache, scheduler: scheduler)
        let model = AppModel(environment: AppEnvironment(reader: f.reader, camera: f.camera, catalog: reopened,
            preview: f.environment.preview, resolver: f.environment.resolver, exports: exports,
            cache: f.environment.cache, thumbnails: f.environment.thumbnails, platform: f.platform))
        await model.start(); await model.connect()
        #expect(model.progressEvents.map(\.jobID) == [job.id])
        let recovered = try #require(model.progressEvents.first)
        #expect(recovered.recipeLabel == recipe.name)
        #expect(recovered.terminal && recovered.summary.completed == 1 && recovered.summary.unresolved == 0)
        #expect(cancelled ? recovered.summary.skipped == 1 : recovered.summary.failed == 1)
        #expect(await f.writer.requests.isEmpty)
        await eventually { model.state.currentCameraExecutionContext != nil }
        await model.resumeExport(jobID: job.id, retry: true)
        await eventually { model.exportEvent?.terminal == true && model.exportEvent?.summary.completed == 2 }
        #expect(await f.writer.requests.map(\.operationID) == [remainingOperation])
        let final = try await reopened.job(id: job.id)
        #expect(final.recipeSnapshot == recipe)
        #expect(final.items[0].state == .saved(savedID))
        #expect(final.items.map(\.operationID) == [savedOperation, remainingOperation])
        #expect(try await reopened.unfinishedJobs().isEmpty)
    }

    nonisolated static func prepare(_ local: LocalResource) throws -> PreparedRAW {
        PreparedRAW(fileURL: local.fileURL, sha256: local.checksum, sourceID: local.token.assetID, sourceRevision: local.token.sourceRevision,
            metadata: RAWMetadata(cameraModel: "X-T5", containerGeometry: PixelSize(width: 1800, height: 1200), recordedGeometry: PixelSize(width: 1800, height: 1200), recordedAspect: PixelSize(width: 3, height: 2), cropTop: 0, cropLeft: 0, orientation: 1))
    }
    func eventually(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }
}
