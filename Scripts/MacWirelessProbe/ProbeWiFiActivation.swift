import FujiCameraCore

@MainActor
enum ProbeWiFiActivation {
  static func activate(
    camera: SavedCamera, selected: WirelessCameraID?, gateway: any BluetoothGateway
  ) async throws -> CameraNetwork {
    try Task.checkCancellation()
    guard camera.id == selected else { throw WirelessFailure.peerMismatch }
    let identity = try await gateway.identity(for: camera.id)
    guard identity.cameraID == camera.id, identity.model == camera.model else {
      throw WirelessFailure.peerMismatch
    }
    guard WirelessSupportPolicy().assess(model: identity.model.rawValue, firmware: identity.firmware)
      == .supported(identity.model)
    else { throw WirelessFailure.unsupportedFirmware }

    try Task.checkCancellation()
    let network = try await gateway.activateWiFi(for: camera.id)
    try Task.checkCancellation()
    guard network.credential.cameraID == camera.id else { throw WirelessFailure.peerMismatch }
    return network
  }
}
