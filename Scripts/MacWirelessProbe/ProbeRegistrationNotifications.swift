import Foundation
import FujiCameraCore

struct ProbeRegistrationNotificationEntry {
  let timestamp: Date
  let message: String
}

struct ProbeRegistrationNotifications {
  private struct Request {
    let peripheralID: UUID
    var session: UUID?
    var verified = false
    var ready = false
    var observing = true
  }

  private static let maximumEntries = 64
  private static let configuration = "4c0020fe-f3b6-40de-acc9-77d129067b14"
  private static let network = "4e941240-d01d-46b9-a5ea-67636806830b"
  private static let roles: [BLEGATTCharacteristic: String] = [
    .init(service: configuration, characteristic: "a68e3f66-0fcc-4395-8d4c-aa980b5877fa"): "readiness",
    .init(service: configuration, characteristic: "bd17ba04-b76b-4892-a545-b73ba1f74dae"): "second-indication",
    .init(service: configuration, characteristic: "f9150137-5d40-4801-a8dc-f7fc5b01da50"): "configuration",
    .init(service: configuration, characteristic: "ad06c7b7-f41a-46f4-a29a-712055319122"): "geotag-request",
    .init(service: network, characteristic: "bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4"): "network-name",
    .init(service: network, characteristic: "75823784-fbb7-4b71-abae-cd9a34072e3c"): "notification-5",
    .init(service: configuration, characteristic: "e6692c5c-b7cd-44f4-95fc-eda07ce32560"): "notification-6",
    .init(service: network, characteristic: "aab609c4-94dd-4d89-bc60-665d5090b828"): "notification-7",
    .init(service: network, characteristic: "2a125640-706d-4dd1-b420-c0f4ab93c361"): "notification-8",
    .init(service: network, characteristic: "82a9f452-c5ce-4ef5-8203-3fc9a47f8171"): "notification-9",
    .init(service: network, characteristic: "deef7187-3f43-4364-9e22-11a8c8a15951"): "notification-10",
  ]

  private var request: Request?
  private var entries: [ProbeRegistrationNotificationEntry] = []
  private var firstDroppedAt: Date?

  mutating func begin(peripheralID: UUID) {
    request = Request(peripheralID: peripheralID)
    entries.removeAll(keepingCapacity: true)
    firstDroppedAt = nil
  }

  mutating func requestedLink(peripheralID: UUID, session: UUID) {
    guard request?.peripheralID == peripheralID, request?.session == nil else { return }
    request?.session = session
  }

  mutating func markReady(peripheralID: UUID) {
    guard request?.peripheralID == peripheralID, request?.verified == true else { return }
    request?.ready = true
  }

  mutating func pause() { request?.observing = false }

  mutating func pause(session: UUID) {
    if request?.session == session { pause() }
  }

  mutating func receive(_ event: BluetoothDriverEvent, at timestamp: Date) -> [ProbeRegistrationNotificationEntry] {
    switch event {
    case .peerModel(let session, let model) where request?.session == session:
      request?.verified = model.flatMap(WirelessCameraModel.init(bluetoothModelNumber:)) == .xt5
    case .linkFailed(let session, _):
      pause(session: session)
    case .disconnected(let session, _) where request?.session == session:
      request = nil
      if let firstDroppedAt {
        entries.append(.init(timestamp: firstDroppedAt, message: "Registration notifications truncated"))
      }
      let retired = entries
      entries = []
      firstDroppedAt = nil
      return retired
    case .protocolEvent(let session, .notification(let key, let data)):
      guard let request, request.session == session, request.verified, request.observing,
        let role = Self.roles[key], let length = Self.lengthClass(data.count)
      else { break }
      guard entries.count < Self.maximumEntries else {
        if firstDroppedAt == nil { firstDroppedAt = timestamp }
        break
      }
      let timing = request.ready ? "after-ready" : "before-ready"
      entries.append(.init(timestamp: timestamp,
        message: "Registration notification: role=\(role) length_class=\(length) timing=\(timing)"))
    default:
      break
    }
    return []
  }

  private static func lengthClass(_ count: Int) -> String? {
    switch count {
    case 0: "empty"
    case 1...2: "1-2"
    case 3...4: "3-4"
    case 5...32: "5-32"
    case 33...BLEProtocolEvent.maximumAttributeBytes: "33-512"
    default: nil
    }
  }
}
