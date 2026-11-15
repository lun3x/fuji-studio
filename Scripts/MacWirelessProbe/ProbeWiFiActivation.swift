import FujiCameraCore

enum ProbeWiFiLaunch: String, Sendable {
  case standard, imageViewing
}

struct ProbeReadyCameraNetwork: Sendable {
  let network: CameraNetwork
  let identity: WirelessIdentity
  let launch: ProbeWiFiLaunch
}

@MainActor
enum ProbeWiFiActivation {
  static func activate(
    camera: SavedCamera, selected: WirelessCameraID?, gateway: any BluetoothGateway,
    launch: ProbeWiFiLaunch = .standard,
    beforeActivation: () throws -> Void = {}
  ) async throws -> ProbeReadyCameraNetwork {
    try Task.checkCancellation()
    guard camera.model == .xt5 else { throw WirelessFailure.unsupportedProtocol }
    guard camera.id == selected else { throw WirelessFailure.peerMismatch }
    let identity = try await gateway.identity(for: camera.id)
    guard identity.cameraID == camera.id, identity.model == camera.model else {
      throw WirelessFailure.peerMismatch
    }
    guard WirelessSupportPolicy().assess(model: identity.model.rawValue, firmware: identity.firmware)
      == .supported(identity.model)
    else { throw WirelessFailure.unsupportedFirmware }

    try Task.checkCancellation()
    try beforeActivation()
    let network = try await gateway.activateWiFi(for: camera.id)
    try Task.checkCancellation()
    guard network.credential.cameraID == camera.id else { throw WirelessFailure.peerMismatch }
    return ProbeReadyCameraNetwork(network: network, identity: identity, launch: launch)
  }
}
