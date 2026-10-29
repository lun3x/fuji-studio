import Foundation
import FujiCameraCore

@MainActor final class ImageCaptureSessionTransport: CameraSessionTransport {
    let native: ImageCaptureTransport
    init(native: ImageCaptureTransport = ImageCaptureTransport()) { self.native=native }
    func states() async -> AsyncStream<CameraState> { await native.states() }
    func connect() async throws { try await native.connect() }
    func currentSession() throws -> CameraSession { try native.currentSession() }
    func close() async throws { try await native.disconnectAndWaitForConfirmation() }
    func execute(_ command:PTPCommand,data:Data?) async throws -> PTPReply { try await native.execute(command,data:data) }
}
