import Foundation
import Testing
@testable import FujiCameraCore
@testable import FujiStudio

@MainActor struct RawPairAppTests {
    @Test func mixedBatchAdoptsReplacementWithoutLosingChecksOrPausingAndNextExportEditsThePair() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        await model.start(automaticallyConnect: false); await model.connect()
        let recipe = try #require(model.state.recipes.first { $0.slot == 3 })
        let raw = try await f.reader.source(id: "source-1"), paired = try await f.reader.source(id: "source-0")
        #expect(raw.originalResources.jpeg == nil)
        model.send(.sourceTapped(raw.id)); model.send(.select)
        var events = await f.environment.exports.events().makeAsyncIterator()
        let job = try await f.environment.exports.start(sources: [raw, paired], recipe: recipe, destination: .updateOriginal)
        let result = try #require(await terminal(job, events: &events))
        #expect(result.summary.completed == 2, "Export result: \(result)")
        let replacementID = try #require(try await f.writer.sourceReplacements()[raw.id])
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.state.viewedSourceID != replacementID && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.state.viewedSourceID == replacementID)
        #expect(model.state.checkedSourceIDs == [replacementID])
        #expect(!model.sources.contains { $0.id == raw.id })
        #expect(model.sources.count == 3)
        let replacement = try await f.reader.source(id: replacementID)
        #expect(replacement.originalResources.jpeg != nil)
        #expect(try await f.environment.catalog.job(id: job).items.map(\.source) == [raw, paired])
        let baseline = try await f.environment.catalog.versions(sourceID: replacementID)
        #expect(baseline.count == 1 && baseline.first?.destination == .createPair)

        let next = try await f.environment.exports.start(sources: [replacement], recipe: recipe, destination: .updateOriginal)
        #expect(try #require(await terminal(next, events: &events)).summary.completed == 1)
        #expect(try await f.writer.sourceReplacements() == [raw.id: replacementID])
        #expect(try await f.reader.source(id: replacementID).originalResources == replacement.originalResources)
        let versions = try await f.environment.catalog.versions(sourceID: replacementID)
        #expect(versions.count == 2)
        #expect(versions.filter { $0.destination == .updateOriginal }.count == 1)
        #expect(model.state.checkedSourceIDs == [replacementID])
    }

    private func terminal(_ id: UUID, events: inout AsyncStream<ExportEvent>.AsyncIterator) async -> ExportEvent? {
        while let event = await events.next(isolation: #isolation) { if event.jobID == id && event.terminal { return event } }
        return nil
    }
}
