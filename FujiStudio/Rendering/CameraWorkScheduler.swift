import FujiCameraCore
import Foundation

enum CameraSchedulingError: Error, Sendable, Equatable { case exportAlreadyActive, wrongJob }

/// Holds USB ownership for the export job while scheduling individual preview and export items.
actor CameraWorkScheduler: CameraWorkScheduling {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private let arbiter: CameraUseArbiter
    private(set) var exportJobID: UUID?
    private var exportPending = false
    private var active = false
    private var beginning: Waiter?
    private var exports: [Waiter] = []
    private var preview: Waiter?
    var hasDeferredPreview: Bool { preview != nil }

    init(arbiter: CameraUseArbiter = CameraUseArbiter()) { self.arbiter = arbiter }

    func beginExport(jobID: UUID) async throws {
        try Task.checkCancellation()
        guard exportJobID == nil else { throw CameraSchedulingError.exportAlreadyActive }
        exportJobID = jobID // Reserve the job; individual items yield to previews.
        exportPending = true
        do {
            try await arbiter.beginUSBExport(jobID)
            guard exportJobID == jobID else { throw CancellationError() }
            if active { try await wait(kind: .begin) }
            try Task.checkCancellation()
            guard exportJobID == jobID else { throw CancellationError() }
            exportPending = false
        } catch {
            await endExport(jobID: jobID)
            throw error
        }
    }

    func endExport(jobID: UUID) async {
        guard exportJobID == jobID else { return }
        exportJobID = nil
        exportPending = false
        beginning?.continuation.resume(throwing: CancellationError()); beginning = nil
        exports.forEach { $0.continuation.resume(throwing: CancellationError()) }; exports = []
        dispatch()
        await arbiter.endUSBExport(jobID)
    }

    func withPreview<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        if active { try await wait(kind: .preview) }
        else { active = true }
        defer { active = false; dispatch() }
        try Task.checkCancellation()
        return try await operation()
    }

    func withExportItem(jobID: UUID, operation: @Sendable () async throws -> CameraJPEG) async throws -> CameraJPEG {
        try Task.checkCancellation()
        guard exportJobID == jobID, !exportPending else { throw CameraSchedulingError.wrongJob }
        if active { try await wait(kind: .export) } else { active = true }
        defer { active = false; dispatch() }
        try Task.checkCancellation()
        guard exportJobID == jobID else { throw CameraSchedulingError.wrongJob }
        return try await operation()
    }

    private enum Kind { case begin, preview, export }
    private func wait(kind: Kind) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let waiter = Waiter(id: id, continuation: continuation)
                switch kind {
                case .begin: beginning = waiter
                case .export: exports.append(waiter)
                case .preview:
                    preview?.continuation.resume(throwing: CancellationError())
                    preview = waiter
                }
            }
        } onCancel: { Task { await self.cancelWaiter(id) } }
    }

    private func cancelWaiter(_ id: UUID) {
        if beginning?.id == id { beginning?.continuation.resume(throwing: CancellationError()); beginning = nil }
        if preview?.id == id { preview?.continuation.resume(throwing: CancellationError()); preview = nil }
        if let index = exports.firstIndex(where: { $0.id == id }) {
            exports.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    private func dispatch() {
        guard !active else { return }
        if let waiter = beginning { beginning = nil; waiter.continuation.resume() }
        if let waiter = preview {
            preview = nil; active = true; waiter.continuation.resume()
        } else if exportJobID != nil {
            if !exports.isEmpty { active = true; exports.removeFirst().continuation.resume() }
        }
    }
}
