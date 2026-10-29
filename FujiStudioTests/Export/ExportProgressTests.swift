import Foundation
import Testing
@testable import FujiStudio

struct ExportProgressTests {
    @Test func activeBatchCountsSettledItemsWithoutCompletingPendingSaves() throws {
        let event = event(summary: .init(completed: 2, failed: 1, skipped: 1, unprocessed: 3, unresolved: 1))
        let progress = try #require(event.activeProgress)
        #expect(progress.processed == 4)
        #expect(progress.total == 8)
        #expect(progress.fractionCompleted == 0.5)
    }

    @Test func pendingSaveKeepsProgressAtZero() throws {
        let progress = try #require(event(summary: .init(completed: 0, failed: 0, skipped: 0, unprocessed: 2, unresolved: 1)).activeProgress)
        #expect(progress.total == 3)
        #expect(progress.fractionCompleted == 0)
    }

    @Test(arguments: [ExportJobState.saved, .paused, .cancelled, .failed, .unresolved])
    func terminalRunsHideActiveProgress(_ stage: ExportJobState) {
        #expect(event(summary: .init(completed: 1, failed: 0, skipped: 0, unprocessed: 2, unresolved: 0),
            stage: stage, terminal: true).activeProgress == nil)
    }

    @Test func emptyBatchHasNoActiveProgress() {
        let empty = ExportSummary(completed: 0, failed: 0, skipped: 0, unprocessed: 0, unresolved: 0)
        #expect(event(summary: empty).activeProgress == nil)
        #expect(empty.fractionCompleted == 0)
    }

    private func event(summary: ExportSummary, stage: ExportJobState = .pendingSave, terminal: Bool = false) -> ExportEvent {
        ExportEvent(jobID: UUID(), recipeLabel: "Mountain greens", stage: stage, currentItem: nil,
            summary: summary, pauseReason: nil, terminal: terminal, stopRequested: false)
    }
}
