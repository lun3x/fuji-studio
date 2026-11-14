import Foundation
import FujiCameraCore

enum WirelessActivity: Equatable, Sendable {
  case active
  case inactive
  case background
}

enum WirelessBluetoothAuthorization: Equatable, Sendable {
  case allowed
  case notDetermined
  case denied
}

enum WirelessBluetoothReadiness: Equatable, Sendable {
  case idle
  case discovering
  case pairing
  case connecting
  case waitingForCamera
  case ready
  case unavailable
}

enum WirelessWiFiPhase: Equatable, Sendable {
  case idle
  case waitingForBluetooth
  case bluetoothReady
}

struct WirelessConnectionIntent: Equatable, Sendable {
  let cameraID: WirelessCameraID
  let connectionGeneration: UInt64
}

struct WirelessConnectionState: Equatable, Sendable {
  var activity: WirelessActivity = .background
  var savedCameras: [SavedCamera] = []
  var selectedCameraID: WirelessCameraID?
  var discoveredCameras: [DiscoveredCamera] = []
  var bluetooth: WirelessBluetoothReadiness = .idle
  var wifi: WirelessWiFiPhase = .idle
  var failure: WirelessFailure?
  var wifiFailure: WirelessFailure?
  var pairingFailure: BluetoothPairingFailure?
  var connectionGeneration: UInt64 = 0
}
