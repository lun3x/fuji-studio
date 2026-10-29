@testable import FujiCameraCore
import Testing
@testable import FujiStudio

@MainActor struct PreviewLoadingTests {
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

    private func eventually(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }
}
