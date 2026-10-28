import SwiftUI
import Testing
@testable import FujiStudio

@MainActor struct PhotoTransitionTests {
    @Test func nextPhotoKeepsPreviousImageWhileItsOriginalLoads() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment), barrier = FixtureBarrier()
        defer { Task { await barrier.release() } }
        await model.start(); model.send(.sourceTapped("source-0"))
        await eventually { model.displayFile != nil && model.imageLoading == nil }
        let original = try #require(model.displayFile)
        await f.reader.holdMaterialize("source-2", barrier: barrier)
        model.send(.sourceTapped("source-2")); await barrier.entered()
        #expect(model.displayFile === original)
        #expect(model.imageLoading == .loading)
        #expect(model.detail == nil)
        #expect(model.state.viewedSourceID == "source-2")
        await barrier.release()
        await eventually { model.displayFile != nil && model.displayFile !== original && model.imageLoading == nil }
        #expect(model.imageStatus == nil)
        #expect(await f.camera.renderCount == 0)
        #expect(await f.writer.requests.isEmpty)
    }

    @Test func failedNewOriginalStopsDisplayingThePreviousPhoto() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment), barrier = FixtureBarrier()
        defer { Task { await barrier.release() } }
        await model.start(); model.send(.sourceTapped("source-0"))
        await eventually { model.displayFile != nil && model.imageLoading == nil }
        let original = try #require(model.displayFile)
        await f.reader.holdMaterialize("source-2", barrier: barrier)
        await f.reader.failMaterialize("source-2", error: .retrievalFailed("Fixture transfer failed"))
        model.send(.sourceTapped("source-2")); await barrier.entered()
        #expect(model.displayFile === original)
        #expect(model.imageLoading == .loading)
        await barrier.release()
        await eventually { model.imageStatusIsFailure && model.imageLoading == nil }
        #expect(model.displayFile == nil)
        #expect(model.state.viewedSourceID == "source-2")
        #expect(model.state.displayedVersion == .cameraJPEG)
        #expect(await f.writer.requests.isEmpty)
    }

    @Test func quickSelectionsKeepLastReadyImageAndRejectLateOriginal() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        let first = FixtureBarrier(), latest = FixtureBarrier()
        defer { Task { await first.release(); await latest.release() } }
        await model.start(); model.send(.sourceTapped("source-0"))
        await eventually { model.displayFile != nil && model.imageLoading == nil }
        let original = try #require(model.displayFile)
        await f.reader.holdMaterialize("source-1", barrier: first)
        await f.reader.holdMaterialize("source-2", barrier: latest)
        model.send(.sourceTapped("source-1")); await first.entered()
        #expect(model.displayFile === original)
        model.send(.sourceTapped("source-2")); await latest.entered()
        #expect(model.displayFile === original)
        await latest.release()
        await eventually { model.displayFile != nil && model.displayFile !== original && model.imageLoading == nil }
        let current = model.displayFile
        await first.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.displayFile === current)
        #expect(model.state.viewedSourceID == "source-2")
        #expect(model.imageStatus == nil)
        #expect(await f.writer.requests.isEmpty)
    }

    @Test func removedPreviousSourceIsDiscardedWhileNewPhotoLoads() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment), barrier = FixtureBarrier()
        defer { Task { await barrier.release() } }
        await model.start(); model.send(.sourceTapped("source-0"))
        await eventually { model.displayFile != nil && model.imageLoading == nil }
        let original = try #require(model.displayFile)
        await f.reader.holdMaterialize("source-2", barrier: barrier)
        model.send(.sourceTapped("source-2")); await barrier.entered()
        #expect(model.displayFile === original)
        await f.reader.restrictTo(["source-2"]); await model.reloadLibrary()
        #expect(model.displayFile == nil)
        #expect(model.imageLoading == .loading)
        await barrier.release()
        await eventually { model.displayFile != nil && model.imageLoading == nil }
        #expect(model.state.viewedSourceID == "source-2")
        #expect(await f.writer.requests.isEmpty)
    }

    @Test func suspendedPhotoSwitchKeepsPlaceholderLoadingThroughForegroundDiscovery() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        let transfer = FixtureBarrier(), discovery = FixtureBarrier()
        defer { Task { await transfer.release(); await discovery.release() } }
        await model.start(); model.send(.sourceTapped("source-0"))
        await eventually { model.displayFile != nil && model.imageLoading == nil }
        let original = try #require(model.displayFile)
        await f.reader.holdMaterialize("source-2", barrier: transfer)
        model.send(.sourceTapped("source-2")); await transfer.entered()
        await model.sceneChanged(.background)
        await f.reader.holdDiscovery(discovery)
        let foreground = Task { await model.sceneChanged(.active) }
        await discovery.entered()
        #expect(model.displayFile === original)
        #expect(model.imageLoading == .loading)
        await discovery.release(); await foreground.value; await transfer.release()
        await eventually { model.displayFile != nil && model.displayFile !== original && model.imageLoading == nil }
        #expect(model.state.viewedSourceID == "source-2")
        #expect(await f.writer.requests.isEmpty)
    }

    @Test func exportStopsFallbackLoadingWithoutLeavingPreviousPhotoVisible() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        let render = FixtureBarrier(), fallback = FixtureBarrier()
        defer { Task { await render.release(); await fallback.release() } }
        await model.start(); await model.connect()
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil && model.imageLoading == nil }
        let original = try #require(model.displayFile)
        await f.camera.holdRender(render); await f.camera.failRenderWithoutDisconnect()
        model.send(.sourceTapped("source-2")); await render.entered()
        await f.reader.holdMaterialize("source-2", barrier: fallback)
        await render.release(); await fallback.entered()
        #expect(model.displayFile === original)
        #expect(model.imageLoading != nil)
        #expect(!model.isLoadingPreview && model.state.canExport)
        #expect(model.state.displayedVersion == .cameraJPEG)
        await model.export()
        #expect(model.displayFile == nil)
        #expect(model.imageLoading == nil)
        #expect(model.imageStatus != nil)
        await fallback.release()
        await eventually { model.exportEvent?.terminal == true }
        #expect(model.exportEvent?.summary.completed == 1)
        #expect(await f.writer.requests.count == 1)
    }

    private func eventually(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }
}
