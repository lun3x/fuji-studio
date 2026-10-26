import Foundation
@testable import FujiStudio

@MainActor final class ControlledCameraDriver: CameraSessionDriver {
    var startCount = 0
    private var events: (@MainActor @Sendable (CameraDriverEvent) -> Void)?
    private var closeCompletions: [@MainActor @Sendable () -> Void] = []
    private var commands: [(@MainActor @Sendable (Result<PTPWireReply, PTPError>) -> Void)] = []
    private var changes: [CheckedContinuation<Void, Never>] = []
    func start(events: @escaping @MainActor @Sendable (CameraDriverEvent) -> Void) {
        self.events = events; startCount += 1; events(.discoveryStarted); changed()
    }
    func close(completion: @escaping @MainActor @Sendable () -> Void) { closeCompletions.append(completion) }
    func send(command: Data, data: Data?, completion: @escaping @MainActor @Sendable (Result<PTPWireReply, PTPError>) -> Void) {
        commands.append(completion); changed()
    }
    func emit(_ event: CameraDriverEvent) { events?(event) }
    func reply(at index: Int, response: Data, data: Data) { commands[index](.success(PTPWireReply(correlation: .directWireTransaction, response: response, data: data))) }
    func finishClose(at index: Int? = nil) { closeCompletions[index ?? (closeCompletions.count - 1)]() }
    func waitForStartCount(_ count: Int) async { while startCount < count { await changedNext() } }
    func waitForCommandCount(_ count: Int) async { while commands.count < count { await changedNext() } }
    private func changedNext() async { await withCheckedContinuation { changes.append($0) } }
    private func changed() { let pending = changes; changes = []; for item in pending { item.resume() } }
}

@MainActor final class ControlledCameraTimeouts: CameraTimeoutScheduling {
    var automaticallyFire = false
    private var history: [@MainActor @Sendable () -> Void] = []
    var scheduledCount: Int { history.count }
    var pendingCount: Int { actions.count }
    func replayScheduled(at index: Int) { history[index]() }
    private var actions: [UUID: @MainActor @Sendable () -> Void] = [:]
    func schedule(after: Duration, action: @escaping @MainActor @Sendable () -> Void) -> UUID {
        let id = UUID(); history.append(action); actions[id] = action; if automaticallyFire { Task { self.fireAll() } }; return id
    }
    func cancel(_ id: UUID) { actions[id] = nil }
    func fireAll() { let pending = actions.values; actions = [:]; for action in pending { action() } }
}
