import Foundation
import FujiCameraCore

protocol AutoSaveGateway: Sendable {
  func checkAvailability() async throws
  func register(camera: SavedCamera) async throws -> AutoSaveRegistration
  func register(
    camera: SavedCamera, onRegistered: @escaping @Sendable () async throws -> Void
  ) async throws -> AutoSaveRegistration
  func savedRegistration(for cameraID: WirelessCameraID) async throws -> AutoSaveRegistration
  func waitForSession(registration: AutoSaveRegistration) async throws -> any WirelessTransferSession
  /// Invalidate the attempt and wait for its native handshake and any unadopted session to close.
  func cancel() async
}

extension AutoSaveGateway {
  func register(camera: SavedCamera) async throws -> AutoSaveRegistration {
    try await register(camera: camera, onRegistered: {})
  }
}

/// Stored in the camera's device-local Keychain record. The importer name is
/// a destination token carried in plaintext by the protocol, not authentication.
struct AutoSaveRegistration: Codable, Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  let cameraID: WirelessCameraID
  private let version: UUID
  private let peerKeyBytes: Data?
  let importer: String
  let cameraName: String

  init(cameraID: WirelessCameraID, peerKey: WirelessProtocolPeerKey?, importer: String, cameraName: String) {
    self.cameraID = cameraID
    self.version = UUID()
    self.peerKeyBytes = peerKey?.bytes
    self.importer = importer
    self.cameraName = cameraName
  }

  var peerKey: WirelessProtocolPeerKey? { peerKeyBytes.map(WirelessProtocolPeerKey.init(bytes:)) }

  var description: String { "[redacted AutoSave registration]" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
}

struct AutoSaveHandshake: Sendable {
  let address: String
  let cameraName: String
}

typealias AutoSaveExchange = @Sendable (
  AutoSaveCodec.Phase, String, String?, ContinuousClock.Instant
) async throws -> AutoSaveHandshake

typealias AutoSaveSessionFactory = @Sendable (
  String, WirelessIdentity, ContinuousClock.Instant
) async throws -> any WirelessTransferSession
