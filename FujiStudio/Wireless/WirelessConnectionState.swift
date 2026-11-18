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
  case acquiringOwnership
  case waitingForBluetooth
  case bluetoothReady
  case activatingCamera
  case joiningNetwork
  case registeringAutoSave
  case verifyingAutoSave
  case waitingForAutoSave
  case openingSession
  case checkingFirmware
  case loadingInventory
  case ready
  case disconnecting
}

enum WirelessTransferRoute: Equatable, Sendable {
  case cameraNetwork
  case autoSave
}

struct WirelessConnectionIntent: Equatable, Sendable {
  let cameraID: WirelessCameraID
  let connectionGeneration: UInt64
}

struct WirelessFirmwareRejection: Error, Equatable, Sendable {
  let cameraModel: WirelessCameraModel
  /// The policy result from fresh PTP DeviceInfo for the authenticated transfer peer.
  let transferAdmission: WirelessAdmission
  let bluetoothRejectedFirmware: Bool

  init(cameraModel: WirelessCameraModel, transferAdmission: WirelessAdmission,
       bluetoothRejectedFirmware: Bool = false) {
    self.cameraModel = cameraModel
    self.transferAdmission = transferAdmission
    self.bluetoothRejectedFirmware = bluetoothRejectedFirmware
  }
}

struct WirelessConnectionState: Equatable, Sendable {
  var sequence: UInt64 = 0
  var activity: WirelessActivity = .background
  var savedCameras: [SavedCamera] = []
  var selectedCameraID: WirelessCameraID?
  var hasLoadedSavedCameraPreference = false
  var discoveredCameras: [DiscoveredCamera] = []
  var bluetooth: WirelessBluetoothReadiness = .idle
  var wifi: WirelessWiFiPhase = .idle
  /// Route of the current or last started transfer attempt.
  var transferRoute: WirelessTransferRoute?
  var failure: WirelessFailure?
  var manualNetwork: CameraNetwork?
  var wifiFailure: WirelessFailure?
  var wifiFailurePhase: WirelessWiFiPhase?
  var firmwareRejection: WirelessFirmwareRejection?
  var verifiedAutoSaveCameraID: WirelessCameraID?
  var pairingFailure: BluetoothPairingFailure?
  var connectionGeneration: UInt64 = 0
  var hasTransferLease = false
  var cameraTransferSizeRestoreUnconfirmed = false

  var showsCameraPhotosButton: Bool {
    if wifi == .ready || manualNetwork != nil { return true }
    return bluetooth == .ready && wifi != .disconnecting && !(wifi == .idle && hasTransferLease)
  }

  var restrictsUSB: Bool { hasTransferLease || wifi != .idle }
}
