@preconcurrency import CoreBluetooth
import Foundation
import FujiCameraCore

/// The delegate queue and every operation on peripheral objects are main-actor isolated.
@MainActor
final class CoreBluetoothDriver: NSObject, BluetoothPeripheralDriver,
  @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate
{
  private struct Link {
    let id: UUID
    let peripheral: CBPeripheral
    var discovering: Set<CBUUID> = []
    var characteristics: [BLEGATTCharacteristic: CBCharacteristic] = [:]
    var pendingRead: BLEGATTCharacteristic?
    var pendingWrite: (characteristic: BLEGATTCharacteristic, purpose: BLEWritePurpose)?
    var closing = false
  }

  var eventHandler: ((BluetoothDriverEvent) -> Void)?
  private var central: CBCentralManager?
  private var discoveries: [UUID: CBPeripheral] = [:]
  private var active: Link?

  private static let secureAdvertisement = CBUUID(string: "a9d2b304-e8d6-4902-8336-352b772d7597")
  private static let legacyAdvertisement = CBUUID(string: "af854c2e-b214-458e-97e2-912c4ecf2cb8")
  private static let xAppAdvertisement = CBUUID(string: "117c4142-edd4-4c77-8696-dd18eebb770a")
  private static let pairingServices = [
    "123d8f06-62a1-4935-9322-833c531ee225",
    "91f1de68-dff6-466e-8b65-ff13b0f16fb8",
    "4c0020fe-f3b6-40de-acc9-77d129067b14",
    "4e941240-d01d-46b9-a5ea-67636806830b",
    "6514eb81-4e8f-458d-aa2a-e691336cdfac",
    "180a",
  ].map(CBUUID.init(string:))
  private static let modelNumber = BLEGATTCharacteristic(service: "180a", characteristic: "2a24")

  func start(allowPermissionPrompt: Bool) throws {
    switch CBManager.authorization {
    case .allowedAlways: break
    case .notDetermined where allowPermissionPrompt: break
    default: throw WirelessFailure.permissionDenied(.bluetooth)
    }
    if central == nil {
      central = CBCentralManager(
        delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }
  }

  func scan() {
    discoveries.removeAll()
    central?.scanForPeripherals(
      withServices: [Self.secureAdvertisement, Self.legacyAdvertisement, Self.xAppAdvertisement],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
  }

  func stopScan() { central?.stopScan() }

  func connect(peripheralID: UUID, session: UUID) {
    guard let central, central.state == .poweredOn, active == nil,
      let peripheral = discoveries[peripheralID]
        ?? central.retrievePeripherals(withIdentifiers: [peripheralID]).first
    else {
      eventHandler?(.disconnected(session, .connectionLost))
      return
    }

    discoveries.removeAll()
    active = Link(id: session, peripheral: peripheral)
    peripheral.delegate = self
    central.connect(peripheral, options: nil)
  }

  func perform(_ action: BLEProtocolAction, session: UUID) {
    guard let link = active, link.id == session, !link.closing else { return }
    let key: BLEGATTCharacteristic
    switch action {
    case .read(let value), .write(let value, _, _), .subscribe(let value): key = value
    case .authenticated, .wifiReady: return
    }
    guard let characteristic = link.characteristics[key] else {
      fail(key, session: session, .unsupportedProtocol)
      return
    }

    switch action {
    case .read:
      guard characteristic.properties.contains(.read) else {
        fail(key, session: session, .unsupportedProtocol)
        return
      }
      active?.pendingRead = key
      link.peripheral.readValue(for: characteristic)
    case .write(_, let data, let purpose):
      guard characteristic.properties.contains(.write),
        data.count <= BLEProtocolEvent.maximumAttributeBytes,
        data.count <= link.peripheral.maximumWriteValueLength(for: .withResponse)
      else {
        fail(key, session: session, .unsupportedProtocol)
        return
      }
      active?.pendingWrite = (key, purpose)
      link.peripheral.writeValue(data, for: characteristic, type: .withResponse)
    case .subscribe:
      let supported: CBCharacteristicProperties = [
        .notify, .indicate, .notifyEncryptionRequired, .indicateEncryptionRequired,
      ]
      guard !characteristic.properties.intersection(supported).isEmpty else {
        eventHandler?(.protocolEvent(session, .subscriptionUnavailable(key)))
        return
      }
      link.peripheral.setNotifyValue(true, for: characteristic)
    case .authenticated, .wifiReady:
      break
    }
  }

  func disconnect(session: UUID) {
    discoveries.removeAll()
    guard let link = active, link.id == session else {
      eventHandler?(.disconnected(session, .connectionLost))
      return
    }
    guard !link.closing else { return }
    active?.closing = true
    if link.peripheral.state == .disconnected || central?.state != .poweredOn {
      finishLink(link, failure: .connectionLost)
    } else {
      central?.cancelPeripheralConnection(link.peripheral)
    }
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    let availability: BluetoothAvailability = switch central.state {
    case .poweredOn: .poweredOn
    case .unauthorized: .unauthorized
    case .unsupported: .unsupported
    case .poweredOff, .resetting: .poweredOff
    case .unknown: .unknown
    @unknown default: .unsupported
    }
    eventHandler?(.availability(availability))
    if let failure = availability.failure, let active {
      finishLink(active, failure: failure)
    }
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi RSSI: NSNumber
  ) {
    guard central.isScanning, discoveries.count < 64 || discoveries[peripheral.identifier] != nil,
      let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
      data.prefix(2).elementsEqual([0xd8, 0x04]),
      advertisementData[CBAdvertisementDataIsConnectable] as? Bool != false
    else { return }
    let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
      + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
    let rawName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
    let name = rawName.map { String($0.prefix(64)) }.flatMap { $0.isEmpty ? nil : $0 }
      ?? "Fujifilm camera"
    let hint = WirelessCameraModel(rawValue: name.uppercased())
    let token: WirelessProtocolPeerKey?
    if services.contains(Self.secureAdvertisement), data.count == 8, hint != .xe3 {
      token = nil
    } else if data.count == 7, data[data.startIndex + 2] == 0x02, hint != .xt5,
      services.contains(Self.legacyAdvertisement) || services.contains(Self.xAppAdvertisement)
    {
      token = WirelessProtocolPeerKey(bytes: Data(data.suffix(4)))
    } else {
      return
    }
    discoveries[peripheral.identifier] = peripheral
    eventHandler?(.discovered(DiscoveredCamera(
      peripheralID: peripheral.identifier, advertisedModelHint: hint, displayName: name), token: token))
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard link(for: peripheral) != nil else { return }
    peripheral.discoverServices(Self.pairingServices)
  }

  func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
  ) {
    disconnected(peripheral, error: error)
  }

  func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
  ) {
    disconnected(peripheral, error: error)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let link = link(for: peripheral) else { return }
    if let error {
      abort(link, failure: Self.failure(from: error))
      return
    }
    let services = peripheral.services ?? []
    let ids = Set(services.map(\.uuid))
    guard ids.count == services.count else {
      abort(link, failure: .unsupportedProtocol)
      return
    }
    active?.discovering = ids
    if services.isEmpty { publishServices(for: link.id) }
    for service in services { peripheral.discoverCharacteristics(nil, for: service) }
  }

  func peripheral(
    _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
  ) {
    guard let link = link(for: peripheral), link.discovering.contains(service.uuid) else { return }
    if let error {
      abort(link, failure: Self.failure(from: error))
      return
    }
    for characteristic in service.characteristics ?? [] {
      guard let key = Self.key(for: characteristic), link.characteristics[key] == nil else {
        abort(link, failure: .unsupportedProtocol)
        return
      }
      active?.characteristics[key] = characteristic
    }
    active?.discovering.remove(service.uuid)
    if active?.discovering.isEmpty == true {
      if let model = active?.characteristics[Self.modelNumber], model.properties.contains(.read) {
        active?.pendingRead = Self.modelNumber
        peripheral.readValue(for: model)
      } else {
        publishServices(for: link.id)
      }
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard let link = link(for: peripheral), let key = Self.key(for: characteristic),
      link.characteristics[key] === characteristic
    else { return }
    let isRead = link.pendingRead == key
    if isRead { active?.pendingRead = nil }
    if isRead, key == Self.modelNumber {
      if let data = characteristic.value, error == nil, data.count <= 64 {
        let text = String(data: data.prefix { $0 != 0 }, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        eventHandler?(.peerModel(link.id, text.flatMap { $0.isEmpty ? nil : $0 }))
      }
      publishServices(for: link.id)
      return
    }
    if let error {
      fail(key, session: link.id, Self.failure(from: error))
      return
    }
    guard let data = characteristic.value, data.count <= BLEProtocolEvent.maximumAttributeBytes else {
      if isRead { fail(key, session: link.id, .malformedData) }
      return
    }
    eventHandler?(.protocolEvent(link.id, isRead ? .read(key, data) : .notification(key, data)))
  }

  func peripheral(
    _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard let link = link(for: peripheral), let key = Self.key(for: characteristic),
      link.characteristics[key] === characteristic, let write = link.pendingWrite,
      write.characteristic == key
    else { return }
    active?.pendingWrite = nil
    if let error {
      let failure = Self.failure(from: error)
      if (write.purpose == .pair || write.purpose == .authenticate), error is CBATTError {
        fail(key, session: link.id, .authentication)
      } else {
        fail(key, session: link.id, failure)
      }
    } else {
      eventHandler?(.protocolEvent(link.id, .wrote(key)))
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard let link = link(for: peripheral), let key = Self.key(for: characteristic),
      link.characteristics[key] === characteristic
    else { return }
    if let error {
      fail(key, session: link.id, Self.failure(from: error))
    } else if characteristic.isNotifying {
      eventHandler?(.protocolEvent(link.id, .subscribed(key)))
    } else {
      fail(key, session: link.id, .unsupportedProtocol)
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
    guard let link = link(for: peripheral), !invalidatedServices.isEmpty else { return }
    abort(link, failure: .connectionLost)
  }

  private func publishServices(for session: UUID) {
    guard let link = active, link.id == session, !link.closing else { return }
    eventHandler?(.protocolEvent(session, .services(Set(link.characteristics.keys))))
  }

  private func link(for peripheral: CBPeripheral) -> Link? {
    guard let link = active, link.peripheral === peripheral, !link.closing else { return nil }
    return link
  }

  private func fail(_ characteristic: BLEGATTCharacteristic, session: UUID, _ error: WirelessFailure) {
    eventHandler?(.protocolEvent(session, .failed(characteristic, error)))
  }

  private func abort(_ link: Link, failure: WirelessFailure) {
    eventHandler?(.linkFailed(link.id, failure))
  }

  private func disconnected(_ peripheral: CBPeripheral, error: Error?) {
    guard let active, active.peripheral === peripheral else { return }
    finishLink(active, failure: error.map(Self.failure) ?? .connectionLost)
  }

  private func finishLink(_ link: Link, failure: WirelessFailure) {
    active = nil
    link.peripheral.delegate = nil
    eventHandler?(.disconnected(link.id, failure))
  }

  private static func key(for characteristic: CBCharacteristic) -> BLEGATTCharacteristic? {
    guard let service = characteristic.service else { return nil }
    return BLEGATTCharacteristic(
      service: service.uuid.uuidString, characteristic: characteristic.uuid.uuidString)
  }

  private static func failure(from error: Error) -> WirelessFailure {
    if let error = error as? CBATTError {
      switch error.code {
      case .insufficientAuthentication, .insufficientAuthorization, .insufficientEncryption,
        .insufficientEncryptionKeySize:
        return .authentication
      default:
        return .unsupportedProtocol
      }
    }
    if let error = error as? CBError {
      switch error.code {
      case .peerRemovedPairingInformation, .encryptionTimedOut: return .authentication
      default: break
      }
    }
    return .connectionLost
  }
}
