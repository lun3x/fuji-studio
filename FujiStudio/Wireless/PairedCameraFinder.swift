@preconcurrency import CoreBluetooth
import Foundation
import FujiCameraCore

@MainActor
struct PairedCameraMatches {
  static let service = CBUUID(string: "123d8f06-62a1-4935-9322-833c531ee225")

  private let eligible: [SavedCamera]
  private let recordsByPeripheral: [UUID: [SavedCamera]]
  private var nearby: Set<UUID> = []

  init(saved: [SavedCamera]) {
    eligible = saved.filter { $0.model == .xt5 }
    recordsByPeripheral = Dictionary(grouping: saved, by: \.peripheralID)
      .filter { $0.value.contains { $0.model == .xt5 } }
  }

  var cameras: [SavedCamera] {
    eligible.filter { nearby.contains($0.peripheralID) && recordsByPeripheral[$0.peripheralID]?.count == 1 }
  }

  var ambiguous: Bool {
    nearby.contains { (recordsByPeripheral[$0]?.count ?? 0) > 1 }
  }

  var isEmpty: Bool { recordsByPeripheral.isEmpty }
  var foundAll: Bool { nearby.count == recordsByPeripheral.count }

  mutating func receiveSavedPeripheral(_ peripheralID: UUID) {
    if recordsByPeripheral[peripheralID]?.count == 1 { nearby.insert(peripheralID) }
  }

  mutating func receive(peripheralID: UUID, advertisement: [String: Any]) {
    guard recordsByPeripheral[peripheralID] != nil,
      advertisement[CBAdvertisementDataIsConnectable] as? Bool == true,
      let manufacturer = advertisement[CBAdvertisementDataManufacturerDataKey] as? Data,
      manufacturer.count == 8, manufacturer.prefix(2).elementsEqual([0xd8, 0x04])
    else { return }
    let services = (advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
      + (advertisement[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
    if services.contains(Self.service) { nearby.insert(peripheralID) }
  }
}

/// Scan for the registered-camera service and release the central before opening the link.
@MainActor
final class PairedCameraFinder: NSObject, @preconcurrency CBCentralManagerDelegate {
  private var firstMatch = false
  private var matches: PairedCameraMatches
  private var manager: CBCentralManager?
  private var completion: CheckedContinuation<PairedCameraMatches, Error>?
  private var timeout: Task<Void, Never>?

  init(saved: [SavedCamera]) {
    matches = PairedCameraMatches(saved: saved)
  }

  func find(firstMatch: Bool = false) async throws -> PairedCameraMatches {
    try Task.checkCancellation()
    self.firstMatch = firstMatch
    if matches.isEmpty { return matches }
    switch CBManager.authorization {
    case .notDetermined, .allowedAlways: break
    default: throw WirelessFailure.permissionDenied(.bluetooth)
    }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        completion = continuation
        if !firstMatch {
          timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard let self else { return }
            finish(.success(matches))
          }
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
          withServices: [PairedCameraMatches.service],
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
    advertisementData: [String: Any], rssi RSSI: NSNumber
  ) {
    guard central === manager, central.isScanning else { return }
    if firstMatch {
      // iOS can coalesce or omit advertisement fields in the background. The scan
      // already filters the registered service, and the link authenticates the saved peripheral.
      matches.receiveSavedPeripheral(peripheral.identifier)
    } else {
      matches.receive(peripheralID: peripheral.identifier, advertisement: advertisementData)
    }
    if matches.foundAll || (firstMatch && !matches.cameras.isEmpty) { finish(.success(matches)) }
  }

  private func finish(_ result: Result<PairedCameraMatches, Error>) {
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
