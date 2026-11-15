@preconcurrency import CoreBluetooth
import Foundation
import FujiCameraCore

@MainActor
struct SavedAdvertisementObservation {
  static let service = CBUUID(string: "123d8f06-62a1-4935-9322-833c531ee225")

  private(set) var matchingIdentity = false
  private(set) var matchingService = false
  private(set) var matchingShape = false
  private(set) var ready = false

  mutating func receive(matchedPeripheral: Bool, advertisement: [String: Any]) {
    let services = (advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
      + (advertisement[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
    let service = services.contains(Self.service)
    let data = advertisement[CBAdvertisementDataManufacturerDataKey] as? Data
    let shape = data.map { $0.count == 8 && $0.prefix(2).elementsEqual([0xd8, 0x04]) } ?? false
    let connectable = advertisement[CBAdvertisementDataIsConnectable] as? Bool == true

    matchingIdentity = matchingIdentity || matchedPeripheral
    matchingService = matchingService || service
    matchingShape = matchingShape || shape
    ready = ready || (matchedPeripheral && service && shape && connectable)
  }
}

/// A scan-only diagnostic for the saved X-T5 advertisement.
@MainActor
final class ProbeSavedAdvertisementObserver: NSObject, @preconcurrency CBCentralManagerDelegate {
  private let savedPeripheralID: UUID
  private var manager: CBCentralManager?
  private var observation = SavedAdvertisementObservation()
  private var completion: CheckedContinuation<SavedAdvertisementObservation, Error>?
  private var timeout: Task<Void, Never>?

  init(savedPeripheralID: UUID) {
    self.savedPeripheralID = savedPeripheralID
  }

  func observe() async throws -> SavedAdvertisementObservation {
    try Task.checkCancellation()
    guard CBManager.authorization == .allowedAlways else {
      throw WirelessFailure.permissionDenied(.bluetooth)
    }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        completion = continuation
        timeout = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(15)) } catch { return }
          guard let self else { return }
          finish(.success(observation))
        }
        let central = CBCentralManager(
          delegate: nil, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        manager = central
        central.delegate = self
        centralManagerDidUpdateState(central)
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
    }
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard central === manager else { return }
    switch central.state {
    case .poweredOn:
      if !central.isScanning {
        central.scanForPeripherals(
          withServices: [SavedAdvertisementObservation.service],
          options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
      }
    case .unauthorized:
      finish(.failure(WirelessFailure.permissionDenied(.bluetooth)))
    case .poweredOff, .resetting:
      finish(.failure(WirelessFailure.connectionLost))
    case .unsupported:
      finish(.failure(WirelessFailure.unsupportedProtocol))
    case .unknown:
      break
    @unknown default:
      finish(.failure(WirelessFailure.unsupportedProtocol))
    }
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi: NSNumber
  ) {
    guard central === manager else { return }
    observation.receive(matchedPeripheral: peripheral.identifier == savedPeripheralID, advertisement: advertisementData)
    if observation.ready { finish(.success(observation)) }
  }

  private func finish(_ result: Result<SavedAdvertisementObservation, Error>) {
    guard let completion else { return }
    self.completion = nil
    timeout?.cancel()
    timeout = nil
    if manager?.isScanning == true { manager?.stopScan() }
    manager?.delegate = nil
    manager = nil
    completion.resume(with: result)
  }
}
