import Foundation
import FujiCameraCore

protocol SavedCameraStore: Sendable {
  func cameras() async throws -> [SavedCamera]
  func selected() async throws -> WirelessCameraID?
  func save(_ camera: SavedCamera) async throws
  func select(_ id: WirelessCameraID?) async throws
  /// Undo only the candidate written by a superseded pairing attempt.
  func restoreSelection(_ previous: WirelessCameraID?, replacing candidate: WirelessCameraID) async
  func forget(_ id: WirelessCameraID) async throws
}

/// The native WiFi join boundary resolves this reference immediately before association.
protocol CameraNetworkCredentialProvider: Sendable {
  func password(for reference: CameraCredentialReference) async throws -> String
}

@MainActor
protocol AutoSaveRegistrationStore: Sendable {
  func saveAutoSaveRegistration(_ registration: AutoSaveRegistration, for camera: SavedCamera) async throws
  func autoSaveRegistration(for id: WirelessCameraID) async throws -> AutoSaveRegistration?
}

struct CameraCredentialReference: Codable, Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  let cameraID: WirelessCameraID
  let version: UUID

  var description: String { "[redacted camera credential reference]" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
}

struct SavedCamera: Codable, Equatable, Identifiable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  let id: WirelessCameraID
  let peripheralID: UUID
  let model: WirelessCameraModel
  let displayName: String
  var peerKeyReference: CameraCredentialReference? = nil

  var description: String { "Saved camera (\(model.rawValue))" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
}

/// Only the Bluetooth boundary reads or writes pairing credentials.
@MainActor
protocol CameraPairingStore: SavedCameraStore {
  func savePaired(_ camera: SavedCamera, peerKey: WirelessProtocolPeerKey?) throws -> SavedCamera
  func peerKey(for camera: SavedCamera) throws -> WirelessProtocolPeerKey?
  func savePassword(_ password: String, for id: WirelessCameraID) throws -> CameraCredentialReference
}
