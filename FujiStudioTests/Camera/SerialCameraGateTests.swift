import Foundation
import Testing
@testable import FujiStudio

struct SerialCameraGateTests {
    @Test func operationStaysExclusiveAcrossSuspension() async throws {
        let gate = SerialCameraGate(); let wire = PausedCameraSteps()
        let first = Task {
            try await gate.withExclusiveAccess {
                await wire.record("A.upload")
                _ = try await wire.execute(pausedCommand, data: nil)
                await wire.record("A.convert")
                await wire.record("A.download")
            }
        }
        await wire.waitUntilPaused()
        let second = Task { try await gate.withExclusiveAccess { await wire.record("B.upload") } }
        while await gate.queuedOperationCount != 1 { await Task.yield() }
        #expect(await wire.steps == ["A.upload"])
        await wire.release()
        try await first.value; try await second.value
        #expect(await wire.steps == ["A.upload", "A.convert", "A.download", "B.upload"])
    }

    @Test func cancellingQueuedWaiterDoesNotReleaseActiveOperation() async throws {
        let gate = SerialCameraGate(); let wire = PausedCameraSteps()
        let first = Task { try await gate.withExclusiveAccess { await wire.record("A.upload"); _ = try await wire.execute(pausedCommand, data: nil); await wire.record("A.download") } }
        await wire.waitUntilPaused()
        let cancelled = Task { try await gate.withExclusiveAccess { await wire.record("cancelled") } }
        while await gate.queuedOperationCount != 1 { await Task.yield() }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let third = Task { try await gate.withExclusiveAccess { await wire.record("C.upload") } }
        while await gate.queuedOperationCount != 1 { await Task.yield() }
        #expect(await wire.steps == ["A.upload"])
        await wire.release()
        try await first.value; try await third.value
        #expect(await wire.steps == ["A.upload", "A.download", "C.upload"])
    }

    @Test func operationFailureReleasesPermit() async throws {
        let gate = SerialCameraGate()
        await #expect(throws: PTPError.notConnected) {
            try await gate.withExclusiveAccess { throw PTPError.notConnected }
        }
        #expect(try await gate.withExclusiveAccess { 42 } == 42)
    }

    @Test func cancellingActiveOperationDoesNotReleaseUntilOperationReturns() async throws {
        let gate = SerialCameraGate(); let wire = PausedCameraSteps()
        let first = Task { try await gate.withExclusiveAccess { _ = try await wire.execute(pausedCommand, data: nil); await wire.record("A.finished") } }
        await wire.waitUntilPaused()
        first.cancel()
        let second = Task { try await gate.withExclusiveAccess { await wire.record("B.started") } }
        while await gate.queuedOperationCount != 1 { await Task.yield() }
        #expect(await wire.steps.isEmpty)
        await wire.release()
        try await first.value; try await second.value
        #expect(await wire.steps == ["A.finished", "B.started"])
    }
}

private let pausedCommand = PTPCommand(opcode: 0x1001, parameters: [], transactionID: 1)

/// Controllable fake wire transaction: its continuation holds the real gate across an await.
private actor PausedCameraSteps: PTPTransport {
    func execute(_ command: PTPCommand, data: Data?) async throws -> PTPReply {
        await pause()
        return PTPReply(opcode: command.opcode, parameters: [], transactionID: command.transactionID, responseCode: 0x2001, data: Data())
    }

    private(set) var steps: [String] = []
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var pausedWaiters: [CheckedContinuation<Void, Never>] = []
    func record(_ step: String) { steps.append(step) }
    func pause() async {
        await withCheckedContinuation { continuation in
            pauseContinuation = continuation
            let pending = pausedWaiters; pausedWaiters = []; for waiter in pending { waiter.resume() }
        }
    }
    func waitUntilPaused() async {
        if pauseContinuation != nil { return }
        await withCheckedContinuation { pausedWaiters.append($0) }
    }
    func release() { pauseContinuation?.resume(); pauseContinuation = nil }
}
