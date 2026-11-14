import Foundation
import FujiCameraCore

protocol BluetoothGateway: Sendable {
  func discover() async throws -> AsyncThrowingStream<[DiscoveredCamera], Error>
  func pair(_ camera: DiscoveredCamera) async throws -> SavedCamera
  func reconnect(_ camera: SavedCamera) async throws
  func identity(for id: WirelessCameraID) async throws -> WirelessIdentity
  func activateWiFi(for id: WirelessCameraID) async throws -> CameraNetwork
  func events() async -> AsyncStream<BluetoothGatewayEvent>
  func disconnect() async
}

enum BluetoothAvailability: Equatable, Sendable {
  case unknown
  case poweredOn
  case poweredOff
  case unauthorized
  case unsupported

  var failure: WirelessFailure? {
    switch self {
    case .unknown, .poweredOn: nil
    case .poweredOff: .connectionLost
    case .unauthorized: .permissionDenied(.bluetooth)
    case .unsupported: .unsupportedProtocol
    }
  }
}

enum BluetoothGatewayEvent: Equatable, Sendable {
  case availability(BluetoothAvailability)
  case disconnected(WirelessCameraID, WirelessFailure)
}

enum BluetoothPairingFailure: Error, Equatable, Sendable {
  case unresolvedModel
}

struct DiscoveredCamera: Equatable, Identifiable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  let peripheralID: UUID
  let advertisedModelHint: WirelessCameraModel?
  let displayName: String

  var id: UUID { peripheralID }
  var description: String { "Discovered camera (\(advertisedModelHint?.rawValue ?? "unresolved model"))" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
}

struct CameraNetwork: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  enum Security: Equatable, Sendable {
    case wpaPersonal
  }

  let ssid: String
  let security: Security
  let credential: CameraCredentialReference
  let isHidden: Bool

  var description: String { "Protected camera network" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
}
