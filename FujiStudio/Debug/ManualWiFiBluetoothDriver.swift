#if DEBUG
import Foundation
import FujiCameraCore

/// The normal profile still owns authentication, firmware and the readiness notification.
@MainActor
final class ManualWiFiBluetoothDriver: BluetoothPeripheralDriver {
  private let native: any BluetoothPeripheralDriver
  private var link: (peripheralID: UUID, session: UUID, verifiedXT5: Bool)?
  private var imageViewing: ProbeImageViewingLaunch?
  var eventHandler: ((BluetoothDriverEvent) -> Void)?

  init(native: any BluetoothPeripheralDriver = CoreBluetoothDriver()) {
    self.native = native
    native.eventHandler = { [weak self] in self?.receive($0) }
  }

  func beginImageViewing(peripheralID: UUID, selectionIsCurrent: @escaping () -> Bool) throws {
    guard let link, link.peripheralID == peripheralID, link.verifiedXT5,
      selectionIsCurrent(), imageViewing == nil
    else { throw WirelessFailure.peerMismatch }
    imageViewing = ProbeImageViewingLaunch(session: link.session, selectionIsCurrent: selectionIsCurrent)
  }

  func start(allowPermissionPrompt: Bool) throws { try native.start(allowPermissionPrompt: allowPermissionPrompt) }
  func scan() { native.scan() }
  func stopScan() { native.stopScan() }
  func discardDiscoveries() { native.discardDiscoveries() }

  func connect(peripheralID: UUID, session: UUID) {
    imageViewing = nil
    link = (peripheralID, session, false)
    native.connect(peripheralID: peripheralID, session: session)
  }

  func disconnect(session: UUID) {
    clear(session)
    native.disconnect(session: session)
  }

  func perform(_ action: BLEProtocolAction, session: UUID) {
    guard link?.session == session else { return }
    if var viewing = imageViewing {
      let decision = viewing.perform(action, session: session)
      imageViewing = viewing
      guard handle(decision, session: session) else { return }
    } else if case .write(_, _, .activateWiFi) = action {
      eventHandler?(.linkFailed(session, .unsupportedProtocol))
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
    if var viewing = imageViewing {
      let decision = viewing.receive(event)
      imageViewing = viewing
      guard handle(decision, session: viewing.session) else { return }
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
      native.perform(.write(ProbeImageViewingLaunch.launch, Data([0x03, 0x00]), .activateWiFi), session: session)
    case .reject(let failure):
      clear(session)
      eventHandler?(.linkFailed(session, failure))
    }
    return false
  }

  private func clear(_ session: UUID) {
    guard link?.session == session else { return }
    link = nil
    imageViewing = nil
  }
}
#endif
