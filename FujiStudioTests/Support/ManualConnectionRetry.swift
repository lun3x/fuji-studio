@testable import FujiCameraCore
import Foundation

/// Advances the actual AppModel retry loop without waiting on wall-clock time.
actor ManualConnectionRetry {
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var delays: [Duration] = []
    var isWaiting: Bool { !pending.isEmpty }

    func wait(_ delay: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                delays.append(delay); pending[id] = continuation
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func advance() {
        let waiting = pending; pending = [:]
        for continuation in waiting.values { continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
