import CoreBluetooth
import Foundation

@main
@MainActor
private struct SavedAdvertisementTests {
  static func main() {
    let manufacturer = Data([0xd8, 0x04, 0, 0, 0, 0, 0, 0])
    let packet: [String: Any] = [
      CBAdvertisementDataServiceUUIDsKey: [SavedAdvertisementObservation.service],
      CBAdvertisementDataManufacturerDataKey: manufacturer,
      CBAdvertisementDataIsConnectable: true,
    ]

    var otherPeer = SavedAdvertisementObservation()
    otherPeer.receive(matchedPeripheral: false, advertisement: packet)
    precondition(!otherPeer.matchingIdentity && otherPeer.matchingService && otherPeer.matchingShape)
    precondition(!otherPeer.ready)

    var partial = SavedAdvertisementObservation()
    partial.receive(matchedPeripheral: true, advertisement: [
      CBAdvertisementDataServiceUUIDsKey: [SavedAdvertisementObservation.service],
      CBAdvertisementDataManufacturerDataKey: Data(manufacturer.dropLast()),
      CBAdvertisementDataIsConnectable: true,
    ])
    precondition(partial.matchingIdentity && partial.matchingService && !partial.matchingShape)
    partial.receive(matchedPeripheral: true, advertisement: [
      CBAdvertisementDataManufacturerDataKey: manufacturer,
      CBAdvertisementDataIsConnectable: true,
    ])
    precondition(partial.matchingShape && !partial.ready, "Readiness combined separate packets")

    var wrongPrefix = SavedAdvertisementObservation()
    var invalid = packet
    invalid[CBAdvertisementDataManufacturerDataKey] = Data(repeating: 0, count: 8)
    wrongPrefix.receive(matchedPeripheral: true, advertisement: invalid)
    precondition(!wrongPrefix.matchingShape && !wrongPrefix.ready)

    var noConnection = SavedAdvertisementObservation()
    invalid = packet
    invalid.removeValue(forKey: CBAdvertisementDataIsConnectable)
    noConnection.receive(matchedPeripheral: true, advertisement: invalid)
    precondition(!noConnection.ready)
    invalid[CBAdvertisementDataIsConnectable] = false
    noConnection.receive(matchedPeripheral: true, advertisement: invalid)
    precondition(!noConnection.ready)

    var normal = SavedAdvertisementObservation()
    normal.receive(matchedPeripheral: true, advertisement: packet)
    precondition(normal.ready)

    var overflow = SavedAdvertisementObservation()
    overflow.receive(matchedPeripheral: true, advertisement: [
      CBAdvertisementDataOverflowServiceUUIDsKey: [SavedAdvertisementObservation.service],
      CBAdvertisementDataManufacturerDataKey: manufacturer,
      CBAdvertisementDataIsConnectable: true,
    ])
    precondition(overflow.ready)
    print("Saved advertisement identity, shape, service, and readiness checks passed.")
  }
}
