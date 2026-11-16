#if DEBUG
import Foundation
import FujiCameraCore

/// A closed set of diagnostic fields for the manual Bluetooth path.
@MainActor
final class ManualWiFiBluetoothTrace {
  enum PeerModel: String, Encodable {
    case xt5, xe3, unrecognized, unavailable
  }

  enum Subscription: String, CaseIterable, Encodable {
    case readiness, secondIndication, configuration, geotag, ssid

    /// Diagnostic labels for the five X-T5 profile subscriptions under investigation.
    var characteristic: BLEGATTCharacteristic {
      let configurationService = "4c0020fe-f3b6-40de-acc9-77d129067b14"
      switch self {
      case .readiness:
        return BLEGATTCharacteristic(service: configurationService,
          characteristic: "a68e3f66-0fcc-4395-8d4c-aa980b5877fa")
      case .secondIndication:
        return BLEGATTCharacteristic(service: configurationService,
          characteristic: "bd17ba04-b76b-4892-a545-b73ba1f74dae")
      case .configuration:
        return BLEGATTCharacteristic(service: configurationService,
          characteristic: "f9150137-5d40-4801-a8dc-f7fc5b01da50")
      case .geotag:
        return BLEGATTCharacteristic(service: configurationService,
          characteristic: "ad06c7b7-f41a-46f4-a29a-712055319122")
      case .ssid:
        return BLEGATTCharacteristic(service: "4e941240-d01d-46b9-a5ea-67636806830b",
          characteristic: "bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4")
      }
    }

    init?(_ characteristic: BLEGATTCharacteristic) {
      guard let label = Self.allCases.first(where: { $0.characteristic == characteristic }) else { return nil }
      self = label
    }
  }

  enum SubscriptionResult: String, Encodable {
    case requested, accepted, notDiscovered, unavailable, failed
  }

  enum Readiness: String, Encodable {
    case positive, negative, unrecognized

    init(_ bytes: Data) {
      // Same status rule as FujiBLEHandshake. The trace only stores the class and length.
      switch (bytes.count, bytes.first) {
      case (1...2, 1?): self = .positive
      case (1...2, 0?): self = .negative
      default: self = .unrecognized
      }
    }
  }

  enum Event: Encodable, Equatable {
    case connectionRequested
    case peerModel(PeerModel)
    case subscription(Subscription, SubscriptionResult)
    case activationAuthorized
    case activationRejected(ManualWiFiEvent.Failure)
    case passwordReadRequested
    case passwordReadCompleted
    case passwordReadFailed(ManualWiFiEvent.Failure)
    case standard04Submitted
    case launchWriteAcknowledged
    case launchWriteFailed(ManualWiFiEvent.Failure)
    case readiness(Readiness, length: Int)
    case linkFailed(ManualWiFiEvent.Failure)
    case disconnectRequested
    case disconnected(ManualWiFiEvent.Failure)
  }

  private struct Record: Encodable {
    let timestamp = Date()
    let attempt: Int
    let event: Event
  }

  private static let recordLimit = 128
  private let file: URL?
  private var records: [Record] = []

  init(file: URL?) {
    self.file = file
    write()
  }

  static func live() -> ManualWiFiBluetoothTrace {
    let documents = try? FileManager.default.url(
      for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    return ManualWiFiBluetoothTrace(file: documents?.appending(path: "ManualWiFiBluetoothTrace.json"))
  }

  func append(attempt: Int, event: Event) {
    if records.count == Self.recordLimit { records.removeFirst() }
    records.append(Record(attempt: attempt, event: event))
    write()
  }

  private func write() {
    guard let file else { return }
    do {
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = .sortedKeys
      try encoder.encode(records).write(to: file, options: [.atomic, .completeFileProtection])
    } catch {
      // A diagnostic storage failure must not affect Bluetooth or expose an underlying error.
    }
  }
}
#endif
