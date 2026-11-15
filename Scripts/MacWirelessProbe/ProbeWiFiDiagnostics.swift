import Foundation
import FujiCameraCore

struct ProbeReconnectNotifications {
  static let geotagRequest = BLEGATTCharacteristic(
    service: "4c0020fe-f3b6-40de-acc9-77d129067b14",
    characteristic: "ad06c7b7-f41a-46f4-a29a-712055319122")
  static let configurationNotification = BLEGATTCharacteristic(
    service: geotagRequest.service, characteristic: "f9150137-5d40-4801-a8dc-f7fc5b01da50")
  static let networkName = BLEGATTCharacteristic(
    service: "4e941240-d01d-46b9-a5ea-67636806830b",
    characteristic: "bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4")

  enum Decision {
    case forward, ignore, submitGeotag, releaseNetworkName
    case reject(WirelessFailure)
  }

  private enum Stage {
    case awaitingConnection, awaitingModel, awaitingServices, awaitingConfigurationSubscription
    case awaitingConfigurationAcknowledgement, awaitingNetworkSubscription, awaitingGeotagAcknowledgement
    case completed, closed
  }

  let peripheralID: UUID
  let selectionIsCurrent: () -> Bool
  private(set) var session: UUID?
  private var stage = Stage.awaitingConnection

  init(peripheralID: UUID, selectionIsCurrent: @escaping () -> Bool) {
    self.peripheralID = peripheralID
    self.selectionIsCurrent = selectionIsCurrent
  }

  mutating func connect(peripheralID: UUID, session: UUID) -> Decision {
    guard stage != .closed else { return .ignore }
    guard stage == .awaitingConnection, self.peripheralID == peripheralID, selectionIsCurrent() else {
      return .reject(.peerMismatch)
    }
    self.session = session
    stage = .awaitingModel
    return .forward
  }

  mutating func perform(_ action: BLEProtocolAction, session: UUID) -> Decision {
    guard stage != .closed else { return .ignore }
    guard self.session == session, selectionIsCurrent() else { return .reject(.peerMismatch) }
    if action == .subscribe(Self.geotagRequest) { return .reject(.unsupportedProtocol) }
    switch stage {
    case .awaitingConfigurationSubscription:
      if action == .subscribe(Self.configurationNotification) {
        stage = .awaitingConfigurationAcknowledgement
      } else if action == .subscribe(Self.networkName) {
        return .reject(.unsupportedProtocol)
      }
      return .forward
    case .awaitingNetworkSubscription where action == .subscribe(Self.networkName):
      stage = .awaitingGeotagAcknowledgement
      return .submitGeotag
    case .completed:
      return .forward
    default:
      return .reject(.unsupportedProtocol)
    }
  }

  mutating func receive(_ event: BluetoothDriverEvent) -> Decision {
    switch event {
    case .peerModel(let session, let model):
      guard stage != .closed else { return .ignore }
      guard self.session == session, selectionIsCurrent(), stage == .awaitingModel,
        model.flatMap(WirelessCameraModel.init(bluetoothModelNumber:)) == .xt5
      else { return .reject(.peerMismatch) }
      stage = .awaitingServices
    case .protocolEvent(let session, let event):
      guard stage != .closed else { return .ignore }
      guard self.session == session, selectionIsCurrent() else { return .reject(.peerMismatch) }
      switch event {
      case .services(let keys):
        guard stage == .awaitingServices,
          keys.isSuperset(of: [Self.configurationNotification, Self.geotagRequest, Self.networkName])
        else { return .reject(.unsupportedProtocol) }
        stage = .awaitingConfigurationSubscription
      case .subscribed(Self.configurationNotification):
        guard stage == .awaitingConfigurationAcknowledgement else { return .reject(.unsupportedProtocol) }
        stage = .awaitingNetworkSubscription
      case .subscribed(Self.geotagRequest):
        guard stage == .awaitingGeotagAcknowledgement else { return .reject(.unsupportedProtocol) }
        stage = .completed
        return .releaseNetworkName
      case .subscriptionUnavailable(Self.configurationNotification),
        .subscriptionUnavailable(Self.geotagRequest):
        return .reject(.unsupportedProtocol)
      case .failed(Self.geotagRequest, let failure):
        return .reject(failure)
      case .notification, .failed:
        break
      default:
        if stage == .awaitingGeotagAcknowledgement { return .reject(.unsupportedProtocol) }
      }
    default:
      break
    }
    return .forward
  }

  mutating func cancel() { stage = .closed }
}

struct ProbeImageViewingLaunch {
  static let password = BLEGATTCharacteristic(
    service: ProbeReconnectNotifications.networkName.service,
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
