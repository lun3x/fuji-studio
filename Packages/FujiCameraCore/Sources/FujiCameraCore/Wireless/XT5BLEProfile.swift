import Foundation

/// Secure GATT handshake from Furble and Libfuji. The transport owns BLE encryption.
public struct XT5BLEProfile: FujiBLEProfile, CustomReflectable {
  private var handshake: FujiBLEHandshake

  public init() {
    typealias GATT = FujiBLEGATT
    handshake = FujiBLEHandshake(
      method: .secure(status: BLEGATTCharacteristic(
        service: GATT.securePair, characteristic: "f557d96b-8284-4667-8793-b971c1deca2a")),
      subscriptions: [
        GATT.readiness, GATT.secondIndication, GATT.configurationNotification, GATT.ssid,
        BLEGATTCharacteristic(
          service: GATT.network, characteristic: "75823784-fbb7-4b71-abae-cd9a34072e3c"),
        BLEGATTCharacteristic(
          service: GATT.configuration, characteristic: "e6692c5c-b7cd-44f4-95fc-eda07ce32560"),
        BLEGATTCharacteristic(
          service: GATT.network, characteristic: "aab609c4-94dd-4d89-bc60-665d5090b828"),
        BLEGATTCharacteristic(
          service: GATT.network, characteristic: "2a125640-706d-4dd1-b420-c0f4ab93c361"),
        BLEGATTCharacteristic(
          service: GATT.network, characteristic: "82a9f452-c5ce-4ef5-8203-3fc9a47f8171"),
        BLEGATTCharacteristic(
          service: GATT.network, characteristic: "deef7187-3f43-4364-9e22-11a8c8a15951"),
      ])
  }

  public mutating func receive(_ event: BLEProtocolEvent) throws -> [BLEProtocolAction] {
    try handshake.receive(event)
  }

  public var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
}
