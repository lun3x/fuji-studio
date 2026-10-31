import Foundation
import Testing
@testable import FujiCameraCore
@testable import FujiStudio

@MainActor struct PairCleanupRecoveryTests {
    @Test func verifiedRemovalIsExplicitAndWorksWithoutTheCameraOrAnotherExport() async throws {
        let f = try await FixtureEnvironment.make(pairCleanupPending: true), model = AppModel(environment: f.environment)
        await model.start(automaticallyConnect: false); await model.connect()
        try await wait { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        let recipe = try #require(model.state.recipes.first { $0.slot == 3 })
        let source = try await f.reader.source(id: "source-1")
        model.send(.sourceTapped(source.id)); model.send(.select)
        var events = await f.environment.exports.events().makeAsyncIterator()
        let id = try await f.environment.exports.start(sources: [source], recipe: recipe, destination: .updateOriginal)
        let initial = try #require(await terminal(id, after: 0, events: &events))
        #expect(initial.summary.unresolved == 1)
        await model.reconcile()
        try await wait { model.exportEvent?.summary.replacementCleanup == 1 }
        #expect(await f.writer.cleanupCalls == 0)
        #expect(try await f.reader.source(id: source.id) == source)
        let renders = await f.camera.renderCount
        await f.camera.disconnect()
        try await wait { model.state.currentCameraExecutionContext == nil && model.canFinishReplacements }
        let beforeFinish = try #require(model.exportEvent).sequence
        await model.finishReplacement(jobID: id)
        let finished = try #require(await terminal(id, after: beforeFinish, events: &events))
        #expect(finished.summary.completed == 1)
        #expect(await f.writer.cleanupCalls == 1)
        #expect(await f.writer.requests.count == 1)
        #expect(await f.camera.renderCount == renders)
        await #expect(throws: ResourceError.self) { try await f.reader.source(id: source.id) }
        #expect(try await f.environment.catalog.job(id: id).state == .saved)
    }
    @Test func verifiedPairIsPresentedAsRemovalPendingRatherThanUnknownSave() {
        let event = ExportEvent(jobID: UUID(), recipeLabel: "Example", stage: .unresolved, currentItem: nil,
            summary: .init(completed: 0, failed: 0, skipped: 0, unprocessed: 0, unresolved: 1, replacementCleanup: 1),
            pauseReason: .unresolvedSave, terminal: true, stopRequested: false)
        #expect(ExportProgressView.status(event) == "RAW+JPEG saved — removal pending")
    }
    @Test(arguments: [false, true])
    func stoppingDuringVerificationDrainsTheWorkerAndClassifiesRemainingItems(_ cancel: Bool) async throws {
        let f = try await FixtureEnvironment.make(pairCleanupPending: true)
        try await f.camera.connect()
        let recipe = try #require(try await f.camera.importRecipes().recipes.first)
        let sources = try await [f.reader.source(id: "source-1"), f.reader.source(id: "source-0")]
        let engine = f.environment.exports
        var events = await engine.events().makeAsyncIterator()
        let id = try await engine.start(sources: sources, recipe: recipe, destination: .updateOriginal)
        let initial = try #require(await terminal(id, after: 0, events: &events))
        #expect(initial.summary.unresolved == 1 && initial.summary.unprocessed == 1)
        let gate = FixtureBarrier()
        await f.writer.holdLookup(gate)
        try await engine.finishReplacements(jobID: id)
        await gate.entered()
        var stopped = false
        let stopping = Task {
            if cancel { await engine.cancel(jobID: id) } else { await engine.suspend() }
            stopped = true
        }
        while let event = await events.next(isolation: #isolation) { if event.stopRequested { break } }
        #expect(!stopped)
        await gate.release(); await stopping.value
        let final = try #require(await terminal(id, after: initial.sequence, events: &events))
        #expect(final.terminal)
        let job = try await f.environment.catalog.job(id: id)
        #expect(job.items[1].state == (cancel ? .cancelled : .queued))
        #expect(await f.writer.cleanupCalls == 0)
        #expect(await f.writer.requests.count == 1)
        #expect(await f.camera.renderCount == 1)
        #expect(try await f.reader.source(id: sources[0].id) == sources[0])
    }
    private func terminal(_ id: UUID, after: UInt64, events: inout AsyncStream<ExportEvent>.AsyncIterator) async -> ExportEvent? {
        while let event = await events.next(isolation: #isolation) {
            if event.jobID == id && event.terminal && event.sequence > after { return event }
        }
        return nil
    }
    private func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() && ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
