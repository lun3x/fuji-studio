import Foundation

/// Current X-E3 uses the four-byte camera-supplied legacy token.
public struct XE3BLEProfile: FujiBLEProfile, CustomReflectable {
  public enum Intent: Sendable {
    case pair(WirelessProtocolPeerKey)
    case reconnect(WirelessProtocolPeerKey)
  }

  private var handshake: FujiBLEHandshake

  public init(intent: Intent) {
    typealias GATT = FujiBLEGATT
    let characteristic = BLEGATTCharacteristic(
      service: GATT.legacyPair, characteristic: "aba356eb-9633-4e60-b73f-f52516dbd671")
    let method: FujiBLEHandshake.Method
    switch intent {
    case .pair(let key): method = .token(characteristic, key, .pair)
    case .reconnect(let key): method = .token(characteristic, key, .authenticate)
    }
    handshake = FujiBLEHandshake(
      method: method, subscriptions: [
        GATT.ssid, GATT.readiness, GATT.secondIndication, GATT.configurationNotification,
        BLEGATTCharacteristic(
          service: GATT.configuration, characteristic: "049ec406-ef75-4205-a390-08fe209c51f0"),
      ])
  }

  public mutating func receive(_ event: BLEProtocolEvent) throws -> [BLEProtocolAction] {
    try handshake.receive(event)
  }

  public var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
}
