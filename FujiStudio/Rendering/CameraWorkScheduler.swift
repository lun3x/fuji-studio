import FujiCameraCore
import Foundation

enum CameraSchedulingError: Error, Sendable, Equatable { case exportAlreadyActive, wrongJob }

/// Owns admission, not the camera's native operation lifetime. Active work always drains.
/// The separate camera service gate continues to protect recipe imports and direct callers.
actor CameraWorkScheduler: CameraWorkScheduling {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private(set) var exportJobID: UUID?
    private var active = false
    private var beginning: Waiter?
    private var exports: [Waiter] = []
    private var preview: Waiter?
    var hasDeferredPreview: Bool { preview != nil }

    func beginExport(jobID: UUID) async throws {
        try Task.checkCancellation()
        guard exportJobID == nil else { throw CameraSchedulingError.exportAlreadyActive }
        exportJobID = jobID // Reserve the job; individual items yield to previews.
        do {
            if active { try await wait(kind: .begin) }
            try Task.checkCancellation()
        } catch {
            if exportJobID == jobID { exportJobID = nil; dispatch() }
            throw error
        }
    }

    func endExport(jobID: UUID) {
        guard exportJobID == jobID else { return }
        exportJobID = nil
        beginning?.continuation.resume(throwing: CancellationError()); beginning = nil
        exports.forEach { $0.continuation.resume(throwing: CancellationError()) }; exports = []
        dispatch()
    }

    func withPreview(_ operation: @Sendable () async throws -> CameraJPEG) async throws -> CameraJPEG {
        try Task.checkCancellation()
        if active { try await wait(kind: .preview) }
        else { active = true }
        defer { active = false; dispatch() }
        try Task.checkCancellation()
        return try await operation()
    }

    func withExportItem(jobID: UUID, operation: @Sendable () async throws -> CameraJPEG) async throws -> CameraJPEG {
        try Task.checkCancellation()
        guard exportJobID == jobID, beginning == nil else { throw CameraSchedulingError.wrongJob }
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
