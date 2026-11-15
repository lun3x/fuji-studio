import Foundation
import FujiCameraCore

@main
@MainActor
private struct ProbeWiFiActivationTests {
  static func main() async throws {
    checkFirmwareObservation()
    let camera = SavedCamera(id: .init(), peripheralID: UUID(), model: .xt5, displayName: "Synthetic X-T5")
    let gateway = TestGateway(camera: camera)
    let activate = { (selected: WirelessCameraID?) in
      try await ProbeWiFiActivation.activate(camera: camera, selected: selected, gateway: gateway)
    }

    guard await rejects(.peerMismatch, { try await activate(.init()) }) else { exit(1) }

    let target = WirelessSupportPolicy().record(for: camera.model).firmware
    for firmware in [nil, "4.29", "unreadable", "\(target).0"] {
      gateway.firmware = firmware
      guard await rejects(.unsupportedFirmware, { try await activate(camera.id) }) else { exit(1) }
    }

    gateway.firmware = target
    gateway.model = .xe3
    guard await rejects(.peerMismatch, { try await activate(camera.id) }) else { exit(1) }
    precondition(gateway.activations == 0, "An ineligible identity started activation")

    let legacyCamera = SavedCamera(id: .init(), peripheralID: UUID(), model: .xe3, displayName: "Synthetic X-E3")
    let legacyGateway = TestGateway(camera: legacyCamera)
    legacyGateway.firmware = WirelessSupportPolicy().record(for: legacyCamera.model).firmware
    guard await rejects(.unsupportedProtocol, {
      try await ProbeWiFiActivation.activate(
        camera: legacyCamera, selected: legacyCamera.id, gateway: legacyGateway)
    }) else { exit(1) }
    precondition(legacyGateway.activations == 0, "X-E3 identity started X-T5 activation")

    gateway.model = camera.model
    let supportedFirmware = [target, "04.31", "4.99"]
    for firmware in supportedFirmware {
      gateway.firmware = firmware
      let network = try await activate(camera.id)
      precondition(network.credential.cameraID == camera.id)
      precondition(network.security == .wpaPersonal)
    }
    precondition(gateway.activations == supportedFirmware.count)

    gateway.networkCameraID = .init()
    guard await rejects(.peerMismatch, { try await activate(camera.id) }) else { exit(1) }

    gateway.networkCameraID = camera.id
    gateway.cancelBeforeReturn = true
    let cancelled = await Task {
      do {
        _ = try await activate(camera.id)
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }.value
    precondition(cancelled, "Cancelled activation reported readiness")
    print("Probe Wi-Fi activation admission, identity, and cancellation checks passed.")
  }

  private static func checkFirmwareObservation() {
    let cases: [(String?, String)] = [
      (nil, "unavailable"),
      ("", "invalidFormat"),
      ("4.31", "4.31"),
      (" Ver. 04.32 ", "04.32"),
      ("4.32.0", "4.32.0"),
      ("123.456.789", "123.456.789"),
      ("4.32.0.1", "invalidFormat"),
      ("4..32", "invalidFormat"),
      ("9999.1", "invalidFormat"),
      ("serial 4.32", "invalidFormat"),
      ("4.32\nextra", "nonPrintableASCII"),
      ("4.３２", "nonPrintableASCII"),
      ("4.32\0", "nonPrintableASCII"),
      (String(repeating: "9", count: 17), "tooLong"),
    ]
    precondition(cases.allSatisfy { ProbeFirmwareObservation.label($0.0) == $0.1 })
    print("Probe firmware format, bound, and redaction checks passed.")
  }

  private static func rejects(
    _ failure: WirelessFailure, _ action: () async throws -> CameraNetwork
  ) async -> Bool {
    do {
      _ = try await action()
      print("FAIL: activation unexpectedly succeeded")
      return false
    } catch {
      guard error as? WirelessFailure == failure else {
        print("FAIL: unexpected categorical activation failure")
        return false
      }
      return true
    }
  }
}

@MainActor
private final class TestGateway: BluetoothGateway {
  let camera: SavedCamera
  var firmware: String?
  var model: WirelessCameraModel
  var networkCameraID: WirelessCameraID
  var cancelBeforeReturn = false
  var activations = 0

  init(camera: SavedCamera) {
    self.camera = camera
    model = camera.model
    networkCameraID = camera.id
  }

  func identity(for id: WirelessCameraID) async throws -> WirelessIdentity {
    precondition(id == camera.id)
    return WirelessIdentity(cameraID: id, model: model, firmware: firmware)
  }

  func activateWiFi(for id: WirelessCameraID) async throws -> CameraNetwork {
    precondition(id == camera.id)
    activations += 1
    if cancelBeforeReturn { withUnsafeCurrentTask { $0?.cancel() } }
    return CameraNetwork(
      ssid: "synthetic", security: .wpaPersonal,
      credential: CameraCredentialReference(cameraID: networkCameraID, version: UUID()),
      isHidden: true)
  }

  func discover() async throws -> AsyncThrowingStream<[DiscoveredCamera], Error> {
    throw WirelessFailure.connectionLost
  }
  func pair(_ camera: DiscoveredCamera) async throws -> SavedCamera { throw WirelessFailure.connectionLost }
  func reconnect(_ camera: SavedCamera, allowPermissionPrompt: Bool) async throws {
    throw WirelessFailure.connectionLost
  }
  func events() async -> AsyncStream<BluetoothGatewayEvent> { AsyncStream { $0.finish() } }
  func disconnect() async {}
}
