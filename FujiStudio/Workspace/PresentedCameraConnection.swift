import Observation

/// Owns explicit work launched from the status presentation, including work
/// that has not reached a published connection phase.
@MainActor @Observable
final class PresentedCameraConnection {
    enum Owner { case status, autoSave }

    private(set) var isWorking = false
    private var owner: Owner?
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(from owner: Owner, operation: @escaping @MainActor () async -> Void) {
        guard !isWorking else { return }
        self.owner = owner
        isWorking = true
        task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await operation()
            guard !Task.isCancelled else { return }
            self?.task = nil
            self?.isWorking = false
        }
    }

    /// Cleanup owns the pending command so it can keep admission fenced through the drain.
    func cancel(from requestedOwner: Owner? = nil, cleanup: @escaping @MainActor (Task<Void, Never>?) async -> Void) {
        guard let owner, requestedOwner == nil || requestedOwner == owner else { return }
        self.owner = nil
        let pending = task
        pending?.cancel()
        isWorking = true
        task = Task { [weak self] in
            await cleanup(pending)
            self?.task = nil
            self?.isWorking = false
        }
    }
}
