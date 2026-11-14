import Foundation

actor ManualWirelessClock {
  private struct Sleep {
    let deadline: Duration
    let continuation: CheckedContinuation<Void, Error>
  }

  let scheduled: AsyncStream<Duration>
  private let notification: AsyncStream<Duration>.Continuation
  private var now: Duration = .zero
  private var sleeps: [UUID: Sleep] = [:]

  init() {
    (scheduled, notification) = AsyncStream.makeStream()
  }

  func sleep(for delay: Duration) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { continuation in
        sleeps[id] = Sleep(deadline: now + delay, continuation: continuation)
        notification.yield(delay)
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }

  func advance(by elapsed: Duration) {
    now += elapsed
    for id in sleeps.compactMap({ $0.value.deadline <= now ? $0.key : nil }) {
      sleeps.removeValue(forKey: id)?.continuation.resume()
    }
  }

  private func cancel(_ id: UUID) {
    sleeps.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
  }
}
