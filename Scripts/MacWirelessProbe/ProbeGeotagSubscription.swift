import Foundation
import FujiCameraCore

struct ProbeGeotagSubscription {
  static let characteristic = BLEGATTCharacteristic(
    service: "4c0020fe-f3b6-40de-acc9-77d129067b14",
    characteristic: "ad06c7b7-f41a-46f4-a29a-712055319122")
  static let configurationNotification = BLEGATTCharacteristic(
    service: characteristic.service, characteristic: "f9150137-5d40-4801-a8dc-f7fc5b01da50")
  static let networkName = BLEGATTCharacteristic(
    service: "4e941240-d01d-46b9-a5ea-67636806830b",
    characteristic: "bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4")

  enum Failure: String {
    case geotagCharacteristicMissing
    case geotagSubscriptionUnsupported
    case geotagSubscriptionFailed
    case geotagUnexpectedPeer
    case geotagUnexpectedSequence

    var wirelessFailure: WirelessFailure {
      self == .geotagUnexpectedPeer ? .peerMismatch : .unsupportedProtocol
    }
  }

  enum Decision {
    case forward
    case ignore
    case submit(BLEProtocolAction, UUID)
    case release(BLEProtocolAction, UUID)
    case reject(Failure, UUID)
  }

  private enum Stage {
    case awaitingConnection
    case awaitingModel
    case awaitingServices
    case awaitingConfigurationSubscription
    case awaitingConfigurationAcknowledgement
    case awaitingNetworkSubscription
    case awaitingGeotagAcknowledgement(BLEProtocolAction)
    case completed
    case closed
  }

  let peripheralID: UUID
  private(set) var session: UUID?
  private var stage = Stage.awaitingConnection

  init(peripheralID: UUID) {
    self.peripheralID = peripheralID
  }

  mutating func connect(peripheralID: UUID, session: UUID) -> Decision {
    if case .closed = stage { return .reject(.geotagUnexpectedSequence, session) }
    guard case .awaitingConnection = stage, self.peripheralID == peripheralID else {
      return .reject(.geotagUnexpectedPeer, self.session ?? session)
    }
    self.session = session
    stage = .awaitingModel
    return .forward
  }

  mutating func perform(_ action: BLEProtocolAction, session: UUID) -> Decision {
    if case .closed = stage { return .ignore }
    guard self.session == session else { return .reject(.geotagUnexpectedPeer, self.session ?? session) }
    if action == .subscribe(Self.characteristic) { return .reject(.geotagUnexpectedSequence, session) }
    switch stage {
    case .awaitingConfigurationSubscription:
      if action == .subscribe(Self.configurationNotification) {
        stage = .awaitingConfigurationAcknowledgement
      } else if action == .subscribe(Self.networkName) {
        return .reject(.geotagUnexpectedSequence, session)
      }
      return .forward
    case .awaitingNetworkSubscription where action == .subscribe(Self.networkName):
      stage = .awaitingGeotagAcknowledgement(action)
      return .submit(.subscribe(Self.characteristic), session)
    case .completed:
      return .forward
    default:
      return .reject(.geotagUnexpectedSequence, session)
    }
  }

  mutating func receive(_ event: BluetoothDriverEvent) -> Decision {
    switch event {
    case .peerModel(let session, let model):
      if case .closed = stage { return .ignore }
      guard self.session == session, case .awaitingModel = stage,
        model.flatMap(WirelessCameraModel.init(bluetoothModelNumber:)) == .xt5
      else { return .reject(.geotagUnexpectedPeer, self.session ?? session) }
      stage = .awaitingServices
    case .protocolEvent(let session, let protocolEvent):
      if case .closed = stage { return .ignore }
      guard self.session == session else { return .reject(.geotagUnexpectedPeer, self.session ?? session) }
      return receive(protocolEvent, session: session)
    case .linkFailed(let session, _), .disconnected(let session, _):
      if self.session == session { cancel() }
    default:
      break
    }
    return .forward
  }

  mutating func cancel() { stage = .closed }

  private mutating func receive(_ event: BLEProtocolEvent, session: UUID) -> Decision {
    switch event {
    case .services(let keys):
      guard case .awaitingServices = stage else { return .reject(.geotagUnexpectedSequence, session) }
      guard keys.contains(Self.characteristic) else { return .reject(.geotagCharacteristicMissing, session) }
      guard keys.contains(Self.configurationNotification), keys.contains(Self.networkName) else {
        return .reject(.geotagUnexpectedSequence, session)
      }
      stage = .awaitingConfigurationSubscription
    case .subscribed(Self.configurationNotification):
      guard case .awaitingConfigurationAcknowledgement = stage else {
        return .reject(.geotagUnexpectedSequence, session)
      }
      stage = .awaitingNetworkSubscription
    case .subscriptionUnavailable(Self.configurationNotification):
      return .reject(.geotagUnexpectedSequence, session)
    case .subscribed(Self.characteristic):
      guard case .awaitingGeotagAcknowledgement(let held) = stage else {
        return .reject(.geotagUnexpectedSequence, session)
      }
      stage = .completed
      return .release(held, session)
    case .subscriptionUnavailable(Self.characteristic):
      return .reject(.geotagSubscriptionUnsupported, session)
    case .failed(Self.characteristic, _):
      return .reject(.geotagSubscriptionFailed, session)
    default:
      if case .awaitingGeotagAcknowledgement = stage, case .subscribed = event {
        return .reject(.geotagUnexpectedSequence, session)
      }
    }
    return .forward
  }
}
