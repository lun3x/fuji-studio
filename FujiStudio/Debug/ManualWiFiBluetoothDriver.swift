#if DEBUG
import Foundation
import FujiCameraCore

/// The normal profile still owns authentication, firmware and the readiness notification.
@MainActor
final class ManualWiFiBluetoothDriver: BluetoothPeripheralDriver {
  static let phoneDestinationName = "Fuji iPhone"
  private static let identification = BLEGATTCharacteristic(
    service: "123d8f06-62a1-4935-9322-833c531ee225",
    characteristic: "85b9163e-62d1-49ff-a6f5-054b4630d4a1")

  private let native: any BluetoothPeripheralDriver
  private var link: (peripheralID: UUID, session: UUID, verifiedXT5: Bool)?
  private var activationGuard: ProbeImageViewingLaunch?
  var eventHandler: ((BluetoothDriverEvent) -> Void)?

  init(native: any BluetoothPeripheralDriver = CoreBluetoothDriver()) {
    self.native = native
    native.eventHandler = { [weak self] in self?.receive($0) }
  }

  func beginStandardActivation(peripheralID: UUID, selectionIsCurrent: @escaping () -> Bool) throws {
    guard let link, link.peripheralID == peripheralID, link.verifiedXT5,
      selectionIsCurrent(), activationGuard == nil
    else { throw WirelessFailure.peerMismatch }
    activationGuard = ProbeImageViewingLaunch(session: link.session, selectionIsCurrent: selectionIsCurrent)
  }

  func start(allowPermissionPrompt: Bool) throws { try native.start(allowPermissionPrompt: allowPermissionPrompt) }
  func scan() { native.scan() }
  func stopScan() { native.stopScan() }
  func discardDiscoveries() { native.discardDiscoveries() }

  func connect(peripheralID: UUID, session: UUID) {
    activationGuard = nil
    link = (peripheralID, session, false)
    native.connect(peripheralID: peripheralID, session: session)
  }

  func disconnect(session: UUID) {
    clear(session)
    native.disconnect(session: session)
  }

  func perform(_ action: BLEProtocolAction, session: UUID) {
    guard link?.session == session else { return }
    if var guardedLaunch = activationGuard {
      let decision = guardedLaunch.perform(action, session: session)
      activationGuard = guardedLaunch
      guard handle(decision, session: session) else { return }
    } else if case .write(_, _, .activateWiFi) = action {
      eventHandler?(.linkFailed(session, .unsupportedProtocol))
      return
    }
    if link?.verifiedXT5 == true,
      case .write(Self.identification, let bytes, .identify) = action,
      bytes == Data("Fuji Studio".utf8)
    {
      native.perform(.write(Self.identification, Data(Self.phoneDestinationName.utf8), .identify), session: session)
      return
    }
    native.perform(action, session: session)
  }

  private func receive(_ event: BluetoothDriverEvent) {
    switch event {
    case .peerModel(let session, let model) where link?.session == session:
      link?.verifiedXT5 = model.flatMap(WirelessCameraModel.init(bluetoothModelNumber:)) == .xt5
    case .linkFailed(let session, _), .disconnected(let session, _):
      clear(session)
    case .protocolEvent(let session, _) where link?.session != session:
      return
    default: break
    }
    if var guardedLaunch = activationGuard {
      let decision = guardedLaunch.receive(event)
      activationGuard = guardedLaunch
      guard handle(decision, session: guardedLaunch.session) else { return }
    }
    eventHandler?(event)
  }

  private func handle(_ decision: ProbeImageViewingLaunch.Decision, session: UUID) -> Bool {
    switch decision {
    case .forward:
      return true
    case .ignore:
      break
    case .submitImageViewing:
      // The shared guard recognized the profile's standard launch write.
      return true
    case .reject(let failure):
      clear(session)
      eventHandler?(.linkFailed(session, failure))
    }
    return false
  }

  private func clear(_ session: UUID) {
    guard link?.session == session else { return }
    link = nil
    activationGuard = nil
  }
}
#endif
