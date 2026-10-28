import Foundation

/// Value-only session boundary, injectable without exposing framework objects to the service actor.
public protocol CameraSessionTransport: PTPTransport {
  func states() async -> AsyncStream<CameraState>
  func connect() async throws
  func currentSession() async throws -> CameraSession
  func close() async throws
}
