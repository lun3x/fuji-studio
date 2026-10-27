import Foundation

protocol PTPTransport: Sendable {
    func execute(_ command: PTPCommand, data: Data?) async throws -> PTPReply
}

/// Boundary below the real transport, permitting deterministic tests of public API lifecycle callbacks.
/// Calls and event delivery are serialized on MainActor; framework objects never cross this boundary.
@MainActor protocol CameraSessionDriver: AnyObject {
    func start(events: @escaping @MainActor @Sendable (CameraDriverEvent) -> Void)
    /// Completion means the old session has closed or the device has physically disappeared.
    /// An unconfirmed/failed close must NOT invoke completion.
    func close(completion: @escaping @MainActor @Sendable () -> Void)
    func send(command: Data, data: Data?, completion: @escaping @MainActor @Sendable (Result<PTPWireReply, PTPError>) -> Void)
}

struct PTPWireReply: Sendable {
    let correlation: PTPCorrelation
    let response: Data
    let data: Data
}

enum CameraDriverEvent: Sendable {
    case authorizationRequired
    /// Both grants are authorized; emitted immediately before public browser discovery starts.
    /// The transport arms its USB connection deadline on the first event for the current attempt.
    case discoveryStarted
    case opening
    case opened(CameraConnection)
    case removed
    case failed(PTPError)
}

@MainActor protocol CameraTimeoutScheduling: AnyObject {
    func schedule(after: Duration, action: @escaping @MainActor @Sendable () -> Void) -> UUID
    func cancel(_ id: UUID)
}

@MainActor final class CameraTimeoutScheduler: CameraTimeoutScheduling {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    func schedule(after duration: Duration, action: @escaping @MainActor @Sendable () -> Void) -> UUID {
        let id = UUID()
        tasks[id] = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, self.tasks.removeValue(forKey: id) != nil else { return }
            action()
        }
        return id
    }
    func cancel(_ id: UUID) { tasks.removeValue(forKey: id)?.cancel() }
}
