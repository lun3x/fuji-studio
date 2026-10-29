import Foundation
actor FixtureBarrier {
    private var open = false
    private var waiting = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async { waiting = true; if open { return }; await withCheckedContinuation { continuations.append($0) } }
    func entered() async { while !waiting { await Task.yield() } }
    func release() { open = true; continuations.forEach { $0.resume() }; continuations = [] }
}
