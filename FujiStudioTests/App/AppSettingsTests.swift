import Foundation
import Testing
@testable import FujiStudio

@MainActor struct AppSettingsTests {
    @Test func changingSettingDuringSaveOnlyChangesTheNextExport() async throws {
        let suite = "FujiSettingsExport-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.updateOriginalInPhotos = true
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment, settings: settings)
        let barrier = FixtureBarrier()
        defer { Task { await barrier.release() } }
        await model.start(automaticallyConnect: false); await model.connect()
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil }
        await f.writer.holdSave(barrier)
        await model.export(); await barrier.entered()
        settings.updateOriginalInPhotos = false
        await barrier.release()
        await eventually { model.exportEvent?.terminal == true && model.savedVersions.count == 1 }
        #expect(model.savedVersions.first?.destination == .updateOriginal)
        let firstID = try #require(model.exportEvent?.jobID)
        #expect(try await f.environment.catalog.job(id: firstID).destination == .updateOriginal)
        await model.export()
        await eventually { model.exportEvent?.terminal == true && model.exportEvent?.jobID != firstID }
        #expect(await f.writer.requests.count == 2)
        #expect(await f.writer.requests.last?.originalEdit == nil)
        #expect(try await f.environment.catalog.job(id: #require(model.exportEvent?.jobID)).destination == .separatePhoto)
    }

    @Test func preferenceDefaultsOffAndPersistsAcrossInstances() throws {
        let suite = "FujiSettingsTests-\(UUID())", defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(!settings.updateOriginalInPhotos)
        settings.updateOriginalInPhotos = true
        #expect(AppSettings(defaults: defaults).updateOriginalInPhotos)
        settings.updateOriginalInPhotos = false
        #expect(!AppSettings(defaults: defaults).updateOriginalInPhotos)
        let other = try #require(UserDefaults(suiteName: suite + "-other"))
        defer { other.removePersistentDomain(forName: suite + "-other") }
        #expect(!AppSettings(defaults: other).updateOriginalInPhotos)
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
