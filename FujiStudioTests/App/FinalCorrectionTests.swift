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
            originals: pool,
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

    @Test(arguments: [false, true]) func failedPreviewRetainsMatchingOriginalOrPriorPreview(_ priorPreview: Bool) async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        await model.start(); await model.connect()
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        model.send(.sourceTapped("source-0"))
        await eventually { model.displayFile != nil }
        if priorPreview {
            model.send(.recipeSelected(slot: 1))
            await eventually { model.preview != nil }
        }
        let file = try #require(model.displayFile), version = try #require(model.state.displayedVersion)
        let before = await f.camera.renderCount
        await f.environment.cache.invalidate(sourceID: "source-0")
        await f.camera.failRender()
        model.send(.recipeSelected(slot: 3))
        let selected = model.state.selectedRecipe
        await eventually { model.imageStatus?.contains("Reconnect") == true }
        #expect(model.displayFile === file)
        #expect(model.state.displayedVersion == version)
        #expect(model.state.selectedRecipe == selected)
        #expect(FileManager.default.fileExists(atPath: file.fileURL.path))
        #expect(await f.camera.renderCount == before + 1)
        await model.connect()
        await eventually { !model.isRefreshing && model.state.currentCameraExecutionContext != nil }
        #expect(await f.camera.renderCount == before + 1)
    }

    @Test func newSourceFailureResolvesItsOriginalWithoutAnotherCameraRender() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        await model.start(); await model.connect()
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil }
        let old = model.displayFile, selected = model.state.selectedRecipe
        await f.camera.failRender(); model.send(.sourceTapped("source-2"))
        await eventually { model.imageStatus?.contains("Reconnect") == true && model.displayFile != nil }
        #expect(model.displayFile !== old)
        #expect(model.state.viewedSourceID == "source-2" && model.state.displayedVersion == .cameraJPEG)
        #expect(model.state.selectedRecipe == selected)
        #expect(await f.camera.renderCount == 2)
    }

    @Test func staleFailureCannotReplaceNewSourceOriginal() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment), barrier = FixtureBarrier()
        defer { Task { await barrier.release() } }
        await model.start(); await model.connect()
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        model.send(.sourceTapped("source-0")); await eventually { model.displayFile != nil }
        let old = model.displayFile
        await f.camera.holdRender(barrier); await f.camera.failRender()
        model.send(.recipeSelected(slot: 3))
        await eventually { await f.camera.renderCount == 1 }
        model.send(.sourceTapped("source-2")); model.send(.versionSelected(.cameraJPEG))
        await eventually { model.displayFile != nil && model.displayFile !== old }
        let current = model.displayFile
        await barrier.release()
        await eventually { (try? await f.camera.executionContext()) == nil }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.displayFile === current)
        #expect(model.state.viewedSourceID == "source-2" && model.state.displayedVersion == .cameraJPEG)
        #expect(model.imageStatus == nil)
        #expect(await f.camera.renderCount == 1)
    }

    @Test(arguments: [false, true]) func detectedModelSurvivesReloadAndAllButNotRevisionChange(_ fromExport: Bool) async throws {
        let f = try await FixtureEnvironment.make(), reader = CorrectionLibrary(base: f.reader)
        var bytes = Data(repeating: 0, count: 128)
        bytes.replaceSubrange(0..<16, with: Data("FUJIFILMCCD-RAW ".utf8))
        bytes.replaceSubrange(28..<32, with: Data("X-T4".utf8))
        await reader.setRAW("source-0", bytes: bytes)
        let env = try correctionEnvironment(f, reader: reader, prepare: { try RAFMetadataReader().prepare($0) })
        let model = AppModel(environment: env)
        await model.start(); await model.connect()
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        #expect(await reader.rawMaterializations == 0)
        let frozen = try await reader.source(id: "source-0")
        let recipe = try #require(model.state.recipes.first)
        var jobID: UUID?
        if fromExport {
            jobID = try await env.exports.start(sources: [frozen], recipe: recipe)
            await eventually { model.exportEvent?.terminal == true }
        } else {
            model.send(.sourceTapped("source-0")); await eventually { model.displayFile != nil }
            model.send(.versionSelected(.raw))
        }
        await eventually { model.sources.first { $0.id == "source-0" }?.compatibility == .incompatible(model: "X-T4") }
        #expect(!model.state.eligibleSourceIDs.contains("source-0"))
        await model.reloadLibrary()
        model.send(.all(accessibleEligibleSourceIDs: []))
        await eventually { !model.isSelectingAll }
        #expect(model.state.checkedSourceIDs == ["source-1", "source-2"])
        #expect(model.sources.first { $0.id == "source-0" }?.compatibility == .incompatible(model: "X-T4"))
        model.send(.done); model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 1))
        await eventually { model.displayFile != nil }
        #expect(model.state.displayedVersion == .cameraJPEG)
        #expect(model.state.exportDisabledReason == .incompatibleSource(sourceID: "source-0", model: "X-T4"))
        await #expect(throws: ResourceError.incompatibleCamera("X-T4")) {
            _ = try await env.exports.start(sources: [frozen], recipe: recipe)
        }
        #expect(await reader.rawMaterializations == 1)
        #expect(await f.camera.renderCount == 0)
        #expect(await f.writer.requests.isEmpty)
        if let jobID {
            let job = try await env.catalog.job(id: jobID)
            #expect(job.items[0].source == frozen && job.recipeSnapshot == recipe)
        }
        model.send(.recipeSelected(slot: nil))
        _ = try await f.reader.replaceOriginal("source-0", revision: "new-original")
        await model.reloadLibrary()
        #expect(model.sources.first { $0.id == "source-0" }?.compatibility == .unknown)
        #expect(model.state.eligibleSourceIDs.contains("source-0"))
        model.send(.versionSelected(.raw))
        await eventually { await reader.rawMaterializations == 2 }
        await eventually { model.sources.first { $0.id == "source-0" }?.compatibility == .incompatible(model: "X-T4") }
    }

    private func correctionEnvironment(_ f: FixtureEnvironment.Bundle, reader: CorrectionLibrary,
        prepare: @escaping OriginalResourcePool.Prepare = Self.prepare) throws -> AppEnvironment {
        let pool = OriginalResourcePool(reader: reader, prepare: prepare), scheduler = CameraWorkScheduler()
        let renderer = try RawDisplayRenderer(directory: FileManager.default.temporaryDirectory.appendingPathComponent("correction-display-\(UUID())"))
        let resolver = VersionImageResolver(library: reader, catalog: f.environment.catalog, pool: pool, rawRenderer: renderer, cache: f.environment.cache)
        let preview = PreviewCoordinator(pool: pool, camera: f.camera, scheduler: scheduler, cache: f.environment.cache, rawRenderer: renderer,
            storedDisplay: { source, version in try await resolver.resolve(source: source, version: version).lease })
        let exports = ExportCoordinator(reader: reader, camera: f.camera, catalog: f.environment.catalog, writer: f.writer,
            pool: pool, cache: f.environment.cache, scheduler: scheduler)
        return AppEnvironment(reader: reader, camera: f.camera, catalog: f.environment.catalog, originals: pool, preview: preview, resolver: resolver,
            exports: exports, cache: f.environment.cache, thumbnails: f.environment.thumbnails, platform: f.platform)
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
