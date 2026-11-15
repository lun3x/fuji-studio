#if os(macOS) || DEBUG
import Foundation
import FujiCameraCore

struct ProbeImageViewingLaunch {
  static let password = BLEGATTCharacteristic(
    service: "4e941240-d01d-46b9-a5ea-67636806830b",
    characteristic: "e809256a-915c-4967-92e8-53b7d4cad213")
  static let launch = BLEGATTCharacteristic(
    service: "6514eb81-4e8f-458d-aa2a-e691336cdfac",
    characteristic: "600655e6-3637-42f1-8fb2-44efc5c63b13")

  enum Decision {
    case forward, ignore, submitImageViewing
    case reject(WirelessFailure)
  }

  private enum Stage {
    case awaitingPasswordRead, awaitingPassword, awaitingLaunch, submitted, acknowledged, closed
  }

  let session: UUID
  let selectionIsCurrent: () -> Bool
  private var stage = Stage.awaitingPasswordRead

  init(session: UUID, selectionIsCurrent: @escaping () -> Bool) {
    self.session = session
    self.selectionIsCurrent = selectionIsCurrent
  }

  mutating func perform(_ action: BLEProtocolAction, session: UUID) -> Decision {
    guard stage != .closed else { return .ignore }
    guard self.session == session, selectionIsCurrent() else { return .reject(.peerMismatch) }
    switch (stage, action) {
    case (.awaitingPasswordRead, .read(Self.password)):
      stage = .awaitingPassword
      return .forward
    case (.awaitingLaunch, .write(Self.launch, let bytes, .activateWiFi)) where bytes == Data([0x04, 0x00]):
      stage = .submitted
      return .submitImageViewing
    default:
      return .reject(.unsupportedProtocol)
    }
  }

  mutating func receive(_ event: BluetoothDriverEvent) -> Decision {
    guard case .protocolEvent(let session, let event) = event else { return .forward }
    guard stage != .closed else { return .ignore }
    guard self.session == session, selectionIsCurrent() else { return .reject(.peerMismatch) }
    switch (stage, event) {
    case (.awaitingPassword, .read(Self.password, _)):
      stage = .awaitingLaunch
    case (.submitted, .wrote(Self.launch)):
      stage = .acknowledged
    case (_, .notification), (_, .failed):
      break
    default:
      return .reject(.unsupportedProtocol)
    }
    return .forward
  }

  mutating func cancel() { stage = .closed }
}
#endif
