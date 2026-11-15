import Foundation
import FujiCameraCore
import Testing
@testable import FujiStudio

@MainActor
struct ManualWiFiBluetoothDriverTests {
  private let identification = BLEGATTCharacteristic(
    service: "123d8f06-62a1-4935-9322-833c531ee225",
    characteristic: "85b9163e-62d1-49ff-a6f5-054b4630d4a1")

  @Test func onlyReplacesExactIdentityWriteOnVerifiedCurrentXT5Link() {
    let native = Driver()
    let driver = ManualWiFiBluetoothDriver(native: native)
    let original = BLEProtocolAction.write(identification, Data("Fuji Studio".utf8), .identify)
    let otherBytes = BLEProtocolAction.write(identification, Data("Other".utf8), .identify)
    let otherPurpose = BLEProtocolAction.write(identification, Data("Fuji Studio".utf8), .authenticate)
    let otherService = BLEProtocolAction.write(
      BLEGATTCharacteristic(service: "91f1de68-dff6-466e-8b65-ff13b0f16fb8",
        characteristic: "85b9163e-62d1-49ff-a6f5-054b4630d4a1"),
      Data("Fuji Studio".utf8), .identify)
    let oldSession = UUID()
    let currentSession = UUID()
    driver.connect(peripheralID: UUID(), session: oldSession)
    native.eventHandler?(.peerModel(oldSession, "X-T5"))
    driver.connect(peripheralID: UUID(), session: currentSession)
    driver.perform(original, session: oldSession)
    native.eventHandler?(.peerModel(oldSession, "X-T5"))
    driver.perform(original, session: currentSession)
    native.eventHandler?(.peerModel(currentSession, "X-E3"))
    driver.perform(original, session: currentSession)

    native.eventHandler?(.peerModel(currentSession, "FF220001"))
    driver.perform(otherBytes, session: currentSession)
    driver.perform(otherPurpose, session: currentSession)
    driver.perform(otherService, session: currentSession)
    driver.perform(original, session: currentSession)
    driver.disconnect(session: currentSession)
    driver.perform(original, session: currentSession)

    #expect(native.actions == [
      original, original, otherBytes, otherPurpose, otherService,
      .write(identification, Data("Fuji iPhone".utf8), .identify)
    ])
  }

  private final class Driver: BluetoothPeripheralDriver {
    var eventHandler: ((BluetoothDriverEvent) -> Void)?
    var actions: [BLEProtocolAction] = []

    func start(allowPermissionPrompt: Bool) throws {}
    func scan() {}
    func stopScan() {}
    func discardDiscoveries() {}
    func connect(peripheralID: UUID, session: UUID) {}
    func perform(_ action: BLEProtocolAction, session: UUID) { actions.append(action) }
    func disconnect(session: UUID) {}
  }
}
