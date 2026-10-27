import Foundation

/// An explicit FIFO permit held across every await in a complete multi-command operation.
/// Cancellation of an active task cannot release its permit while its operation is still running.
actor SerialCameraGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var occupied = false
    private var waiters: [Waiter] = []
    var queuedOperationCount: Int { waiters.count }

    func withExclusiveAccess<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await acquire(id)
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        // The queued cancellation can race with a permit transfer. The new holder releases its own permit.
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(_ id: UUID) async throws {
        if !occupied { occupied = true; return }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(id: id, continuation: continuation))
        }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().continuation.resume() }
    }
}
