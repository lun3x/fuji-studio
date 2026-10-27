import Foundation

/// Value-only session boundary, injectable without exposing framework objects to the service actor.
protocol CameraSessionTransport: PTPTransport {
    func states() async -> AsyncStream<CameraState>
    func connect() async throws
    func currentSession() async throws -> CameraSession
    func close() async throws
}

@MainActor final class ImageCaptureSessionTransport: CameraSessionTransport {
    let native: ImageCaptureTransport
    init(native: ImageCaptureTransport = ImageCaptureTransport()) { self.native=native }
    func states() async -> AsyncStream<CameraState> { await native.states() }
    func connect() async throws { try await native.connect() }
    func currentSession() throws -> CameraSession { try native.currentSession() }
    func close() async throws { try await native.disconnectAndWaitForConfirmation() }
    func execute(_ command:PTPCommand,data:Data?) async throws -> PTPReply { try await native.execute(command,data:data) }
}
