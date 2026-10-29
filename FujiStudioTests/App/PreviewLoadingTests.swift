@testable import FujiCameraCore
import Testing
@testable import FujiStudio

@MainActor struct PreviewLoadingTests {
    @Test func photoAndRecipeChangesDuringExportRenderQueuePreviewBeforeNextExport() async throws {
        let fixture = try await FixtureEnvironment.make(), render = FixtureBarrier()
        defer { Task { await render.release() } }
        let model = AppModel(environment: fixture.environment)
        await model.start(); await model.connect()
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil && model.state.canExport }
        let frozen = try #require(model.state.selectedRecipe)
        model.send(.select); model.send(.checkedSourcesReplaced(["source-0", "source-1", "source-2"]))
        await fixture.camera.holdRender(render)
        await model.export(); await render.entered()
        await eventually { if case .busy = model.state.cameraState { return true }; return false }
        model.send(.done); model.send(.sourceTapped("source-2")); model.send(.recipeSelected(slot: 2))
        let selected = try #require(model.state.selectedRecipe)
        await eventually { await fixture.scheduler.hasDeferredPreview }
        await render.release()
        await eventually { model.exportEvent?.terminal == true && model.preview?.sourceID == "source-2" && model.imageLoading == nil }
        let requests = await fixture.camera.renderRequests
        // Fixture recipes share settings, so the final export reuses the prioritized preview.
        #expect(requests.map(\.sourceID) == ["source-0", "source-1", "source-2"])
        #expect(requests.map(\.recipeID) == [frozen.id, frozen.id, selected.id])
        #expect(model.exportEvent?.summary.completed == 3)
    }

    @Test func newRecipePreviewFinishesWhileBatchSaveIsStillPending() async throws {
        let fixture = try await FixtureEnvironment.make(), save = FixtureBarrier()
        defer { Task { await save.release() } }
        let model = AppModel(environment: fixture.environment)
        await model.start(); await model.connect()
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil && model.state.canExport }
        model.send(.select)
        model.send(.checkedSourcesReplaced(["source-0", "source-1", "source-2"]))
        await fixture.writer.holdSave(save)
        await model.export(); await save.entered()
        model.send(.done)
        model.send(.sourceTapped("source-2"))
        await eventually { model.preview?.sourceID == "source-2" && model.imageLoading == nil }
        #expect(model.state.selectedRecipe?.slot == 3)
        #expect(model.exportEvent?.terminal == false)
        #expect(model.exportEvent?.summary.completed == 0)
        #expect(await fixture.writer.requests.count == 1)
        await save.release()
        await eventually { model.exportEvent?.terminal == true }
        #expect(model.exportEvent?.summary.completed == 3)
        #expect(await fixture.writer.requests.count == 3)
    }

    @Test(arguments: [false, true]) func switchingPhotosWhileCameraBusyKeepsSpinnerUntilPreviewFinishes(_ clearRecipe: Bool) async throws {
        let fixture = try await FixtureEnvironment.make(), barrier = FixtureBarrier()
        defer { Task { await barrier.release() } }
        let model = AppModel(environment: fixture.environment)
        await model.start(); await model.connect()
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        model.send(.sourceTapped("source-0"))
        await eventually { model.displayFile != nil && model.imageLoading == nil }
        await fixture.camera.holdRender(barrier)
        model.send(.recipeSelected(slot: 1))
        await barrier.entered()
        await eventually { if case .busy = model.state.cameraState { return true }; return false }

        // Let paired JPEGs finish while the earlier native conversion drains.
        // RAW-only selections retain loading until that conversion releases the RAW pool.
        for sourceID in ["source-2", "source-1", "source-0", "source-2", "source-2"] {
            let previous = model.displayFile
            model.send(.sourceTapped(sourceID))
            #expect(model.imageLoading == .loading)
            #expect(model.isLoadingPreview)
            if sourceID != "source-1" {
                await eventually { model.imageIdentity?.sourceID == sourceID && model.displayFile !== previous }
            }
            #expect(model.imageLoading == .loading)
            #expect(model.isLoadingPreview)
        }

        if clearRecipe {
            model.send(.recipeSelected(slot: nil))
            await eventually { model.imageIdentity?.sourceID == "source-2" && model.imageLoading == nil }
            #expect(!model.isLoadingPreview)
        }
        await barrier.release()
        if clearRecipe {
            await eventually { model.state.isCameraReady }
            #expect(model.preview == nil)
            #expect(model.imageLoading == nil)
        } else {
            await eventually { model.preview?.sourceID == "source-2" && model.imageLoading == nil }
            #expect(!model.isLoadingPreview)
            #expect(model.imageStatus == nil)
        }
        #expect(await fixture.writer.requests.isEmpty)
    }

    @Test(arguments: [false, true]) func interruptedConversionClearsSpinnerAfterSwitchingPhotos(_ attention: Bool) async throws {
        let fixture = try await FixtureEnvironment.make(), barrier = FixtureBarrier()
        defer { Task { await barrier.release() } }
        let model = AppModel(environment: fixture.environment)
        await model.start(); await model.connect()
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        model.send(.sourceTapped("source-0"))
        await eventually { model.displayFile != nil && model.imageLoading == nil }
        await fixture.camera.holdRender(barrier)
        if attention { await fixture.camera.failRenderWithAttention("Camera conversion failed") }
        else { await fixture.camera.failRender() }
        model.send(.recipeSelected(slot: 1))
        await barrier.entered()
        await eventually { if case .busy = model.state.cameraState { return true }; return false }
        model.send(.sourceTapped("source-2"))
        await eventually { model.imageIdentity?.sourceID == "source-2" }
        #expect(model.imageLoading == .loading)
        await barrier.release()
        await eventually { !model.isLoadingPreview }
        await eventually { model.imageLoading == nil && model.imageStatus == nil }
        #expect(model.imageIdentity?.sourceID == "source-2")
        #expect(model.preview == nil)
    }

    @Test(arguments: [false, true]) func completedDownloadShowsSpinnerUntilCameraFinishes(_ fails: Bool) async throws {
        let fixture = try await FixtureEnvironment.make(), barrier = FixtureBarrier()
        defer { Task { await barrier.release() } }
        let model = AppModel(environment: fixture.environment)
        await model.start(); await model.connect()
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        model.send(.sourceTapped("source-0"))
        await eventually { model.displayFile != nil && model.imageStatus == nil }
        let original = try #require(model.displayFile)
        await fixture.camera.holdRender(barrier)
        if fails { await fixture.camera.failRender() }
        model.send(.recipeSelected(slot: 1))
        #expect(model.imageLoading == .loading)
        await barrier.entered()
        // Photos has finished; the camera has no measurable conversion progress.
        await eventually { model.imageStatus?.contains("100%") == true }
        #expect(model.imageLoading == .loading)
        #expect(model.displayFile === original)
        await barrier.release()
        await eventually {
            model.imageLoading == nil && model.imageStatus == nil && model.displayFile != nil
                && (fails ? model.state.selectedRecipe == nil : model.preview != nil)
        }
        #expect(await fixture.writer.requests.isEmpty)
    }

    private func eventually(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition(), sourceLocation: sourceLocation)
    }
}
