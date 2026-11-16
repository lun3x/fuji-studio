import CoreBluetooth
import Foundation
import FujiCameraCore
import Testing
@testable import FujiStudio

@MainActor
struct ManualPairedCameraFinderTests {
  @Test func requiresSavedServiceExactPeripheralManufacturerShapeAndConnectability() {
    let camera = saved()
    let unsupported = saved(model: .xe3)
    var matches = ManualPairedCameraMatches(saved: [camera, unsupported])
    let paired = ManualPairedCameraMatches.service
    let pairingOnly = CBUUID(string: "a9d2b304-e8d6-4902-8336-352b772d7597")
    matches.receive(peripheralID: UUID(), advertisement: advertisement(paired))
    matches.receive(peripheralID: unsupported.peripheralID, advertisement: advertisement(paired))
    matches.receive(peripheralID: camera.peripheralID, advertisement: advertisement(pairingOnly))
    matches.receive(peripheralID: camera.peripheralID, advertisement: advertisement(paired, bytes: [0xd8, 0x04]))
    matches.receive(peripheralID: camera.peripheralID, advertisement: advertisement(paired, bytes: Array(repeating: 0, count: 8)))
    matches.receive(peripheralID: camera.peripheralID, advertisement: advertisement(paired, connectable: false))
    #expect(matches.cameras.isEmpty)
    matches.receive(peripheralID: camera.peripheralID, advertisement: advertisement(paired, overflow: true))
    #expect(matches.cameras == [camera])
  }

  @Test func returnsAllUnambiguousLiveCamerasAndFlagsDuplicateRecords() {
    let first = saved()
    let second = saved()
    let ambiguous = saved()
    let alias = saved(peripheralID: ambiguous.peripheralID)
    let unseen = saved()
    var matches = ManualPairedCameraMatches(saved: [first, second, ambiguous, alias, unseen])
    let packet = advertisement(ManualPairedCameraMatches.service)
    for camera in [second, ambiguous, first, second] {
      matches.receive(peripheralID: camera.peripheralID, advertisement: packet)
    }
    #expect(matches.cameras == [first, second])
    #expect(matches.ambiguous)
    #expect(!matches.foundAll)
  }

  private func saved(peripheralID: UUID = UUID(), model: WirelessCameraModel = .xt5) -> SavedCamera {
    SavedCamera(id: WirelessCameraID(), peripheralID: peripheralID, model: model, displayName: "Saved name")
  }

  private func advertisement(
    _ service: CBUUID, bytes: [UInt8] = [0xd8, 0x04, 0, 0, 0, 0, 0, 0], connectable: Bool = true,
    overflow: Bool = false
  ) -> [String: Any] {
    [
      overflow ? CBAdvertisementDataOverflowServiceUUIDsKey : CBAdvertisementDataServiceUUIDsKey: [service],
      CBAdvertisementDataManufacturerDataKey: Data(bytes),
      CBAdvertisementDataIsConnectable: connectable,
      CBAdvertisementDataLocalNameKey: "Different or irrelevant model text"
    ]
  }
}
