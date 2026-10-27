import Foundation

/// Admission must enclose RAW preparation and camera use, never an already materialized RAF.
protocol CameraWorkScheduling: Sendable {
    func withPreview(_ operation: @Sendable () async throws -> CameraJPEG) async throws -> CameraJPEG
    func withExportItem(jobID: UUID, operation: @Sendable () async throws -> CameraJPEG) async throws -> CameraJPEG
    func beginExport(jobID: UUID) async throws
    func endExport(jobID: UUID) async
}
