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
  }

  var eventHandler: ((BluetoothDriverEvent) -> Void)?
  private var connections = CoreBluetoothConnections<CBCentralManager, CBPeripheral>()
  private var central: CBCentralManager? { connections.manager }
  private var active: Link?
  private let discoverAllServices: Bool

  #if DEBUG
  var observePairing: ((String) -> Void)?
  var observeUnrecognizedModel: ((String) -> Void)?
  #endif

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

  init(discoverAllServices: Bool = false) {
    self.discoverAllServices = discoverAllServices
    super.init()
  }

  func start(allowPermissionPrompt: Bool) throws {
    switch CBManager.authorization {
    case .allowedAlways: break
    case .notDetermined where allowPermissionPrompt: break
    default: throw WirelessFailure.permissionDenied(.bluetooth)
    }
    if central == nil { installCentral() }
  }

  private func installCentral() {
    connections.installManager(CBCentralManager(
      delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false]))
  }

  func scan() {
    discardDiscoveries()
    central?.scanForPeripherals(
      withServices: [Self.secureAdvertisement, Self.legacyAdvertisement, Self.xAppAdvertisement],
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
  }

  func stopScan() { central?.stopScan() }

  func discardDiscoveries() { connections.discardDiscoveries() }

  func connect(peripheralID: UUID, session: UUID) {
    #if DEBUG
    observePairing?("BLE link requested")
    #endif
    guard let central, central.state == .poweredOn,
      let peripheral = connections.begin(
        session: session, peripheralID: peripheralID, manager: central,
        retrieve: { central.retrievePeripherals(withIdentifiers: [peripheralID]).first })
    else {
      eventHandler?(.disconnected(session, .connectionLost))
      return
    }

    active = Link(id: session, peripheral: peripheral)
    peripheral.delegate = self
    central.connect(peripheral, options: nil)
  }

  func perform(_ action: BLEProtocolAction, session: UUID) {
    guard let link = active, link.id == session, connections.active?.closing == false else { return }
    let key: BLEGATTCharacteristic
    switch action {
    case .read(let value), .write(let value, _, _), .subscribe(let value): key = value
    case .authenticated, .wifiReady: return
    }
    #if DEBUG
    let operation: String = switch action {
    case .read: "read"
    case .write: "write"
    case .subscribe: "subscribe"
    case .authenticated, .wifiReady: ""
    }
    observePairing?("BLE \(operation) \(Self.characteristicLabel(key))")
    #endif
    guard let characteristic = link.characteristics[key] else {
      #if DEBUG
      observePairing?("Characteristic missing from discovery")
      #endif
      fail(key, session: session, .unsupportedProtocol)
      return
    }

    switch action {
    case .read:
      guard characteristic.properties.contains(.read) else {
        #if DEBUG
        observePairing?("Read property missing")
        #endif
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
        #if DEBUG
        observePairing?("Write rejected locally; write property \(characteristic.properties.contains(.write))")
        #endif
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
        #if DEBUG
        observePairing?("Subscription properties missing")
        #endif
        eventHandler?(.protocolEvent(session, .subscriptionUnavailable(key)))
        return
      }
      link.peripheral.setNotifyValue(true, for: characteristic)
    case .authenticated, .wifiReady:
      break
    }
  }

  func disconnect(session: UUID) {
    discardDiscoveries()
    switch connections.requestCancellation(for: session, canRequest: central?.state == .poweredOn) {
    case .neverIssued:
      // A retired attempt is completed by the state callback after availability.
      if active?.id != session { eventHandler?(.disconnected(session, .connectionLost)) }
    case .request:
      if let attempt = connections.active {
        attempt.manager.cancelPeripheralConnection(attempt.peripheral)
      }
    case .awaitingTerminal:
      break
    }
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard connections.isCurrent(central) else { return }
    let availability: BluetoothAvailability = switch central.state {
    case .poweredOn: .poweredOn
    case .unauthorized: .unauthorized
    case .unsupported: .unsupported
    case .poweredOff, .resetting: .poweredOff
    case .unknown: .unknown
    @unknown default: .unsupported
    }
    // An unavailable radio can end an attempt without a terminal delegate call.
    // Retire its manager before reusing a peripheral or advertising completion.
    let ended = central.state == .poweredOn ? nil : connections.retireManagerWithAttempt(central)
    #if DEBUG
    if ended != nil { observePairing?("Radio became unavailable: \(availability)") }
    #endif
    if ended != nil {
      central.delegate = nil
      active?.peripheral.delegate = nil
      // A replacement remains an observer while off. It has no attempt to retire.
      installCentral()
    }
    eventHandler?(.availability(availability))
    if let ended {
      finishLink(session: ended, failure: availability.failure ?? .connectionLost)
    }
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi RSSI: NSNumber
  ) {
    guard connections.isCurrent(central), central.state == .poweredOn, central.isScanning,
      connections.canRemember(peripheral.identifier),
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
    connections.remember(peripheral, for: peripheral.identifier)
    eventHandler?(.discovered(DiscoveredCamera(
      peripheralID: peripheral.identifier, advertisedModelHint: hint, displayName: name), token: token))
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard connections.isCurrent(central), link(for: peripheral) != nil else { return }
    #if DEBUG
    observePairing?("BLE link connected; discovering services")
    #endif
    peripheral.discoverServices(discoverAllServices ? nil : Self.pairingServices)
  }

  func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
  ) {
    disconnected(central, peripheral: peripheral, error: error)
  }

  func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
  ) {
    disconnected(central, peripheral: peripheral, error: error)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let link = link(for: peripheral) else { return }
    #if DEBUG
    observePairing?("Service discovery \(Self.errorLabel(error))")
    #endif
    if let error {
      abort(link, failure: Self.failure(from: error))
      return
    }
    let services = peripheral.services ?? []
    let ids = Set(services.map(\.uuid))
    #if DEBUG
    observePairing?("Services present: \(services.map { Self.serviceLabel($0.uuid) }.joined(separator: ", "))")
    #endif
    guard ids.count == services.count else {
      #if DEBUG
      observePairing?("Duplicate services")
      #endif
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
    #if DEBUG
    observePairing?("Characteristic discovery for \(Self.serviceLabel(service.uuid)) \(Self.errorLabel(error))")
    #endif
    if let error {
      abort(link, failure: Self.failure(from: error))
      return
    }
    for characteristic in service.characteristics ?? [] {
      guard let key = Self.key(for: characteristic), link.characteristics[key] == nil else {
        #if DEBUG
        observePairing?("Duplicate characteristic or missing parent service")
        #endif
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
    #if DEBUG
    if isRead {
      observePairing?("Read result for \(Self.characteristicLabel(key)) \(Self.errorLabel(error))")
    }
    #endif
    if isRead, key == Self.modelNumber {
      switch Self.modelRead(characteristic.value, error: error) {
      case .success(let model):
        #if DEBUG
        let observedModel = model.flatMap(WirelessCameraModel.init(bluetoothModelNumber:))
        let modelLabel = observedModel?.rawValue ?? (model == nil ? "unavailable" : "unrecognized")
        observePairing?("Device Information model: \(modelLabel)")
        if let model, observedModel == nil { observeUnrecognizedModel?(model) }
        #endif
        if let model { eventHandler?(.peerModel(link.id, model)) }
        publishServices(for: link.id)
      case .failure(let failure):
        abort(link, failure: failure)
      }
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
    #if DEBUG
    observePairing?("Write result for \(Self.characteristicLabel(key)) \(Self.errorLabel(error))")
    #endif
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
    #if DEBUG
    observePairing?("Subscription result for \(Self.characteristicLabel(key)) \(Self.errorLabel(error)); active \(characteristic.isNotifying)")
    #endif
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
    guard let link = active, link.id == session, connections.active?.closing == false else { return }
    #if DEBUG
    if let observePairing {
      let names = link.characteristics.compactMap { key, characteristic -> String? in
        guard Self.knownCharacteristicLabel(key) != nil else { return nil }
        let properties = characteristic.properties
        let capabilities: [(CBCharacteristicProperties, String)] = [
          (.read, "read"), (.write, "write"), (.writeWithoutResponse, "write without response"),
          (.notify, "notify"), (.indicate, "indicate"),
          (.notifyEncryptionRequired, "encrypted notify"), (.indicateEncryptionRequired, "encrypted indicate"),
        ]
        let flags = capabilities.compactMap { properties.contains($0.0) ? $0.1 : nil }
        return "\(Self.characteristicLabel(key)) [\(flags.joined(separator: ", "))]"
      }.sorted()
      observePairing("Characteristics present: \(names.joined(separator: ", "))")
    }
    #endif
    eventHandler?(.protocolEvent(session, .services(Set(link.characteristics.keys))))
  }

  private func link(for peripheral: CBPeripheral) -> Link? {
    guard let link = active, link.peripheral === peripheral, connections.active?.closing == false
    else { return nil }
    return link
  }

  private func fail(_ characteristic: BLEGATTCharacteristic, session: UUID, _ error: WirelessFailure) {
    #if DEBUG
    observePairing?("Protocol operation failed for \(Self.characteristicLabel(characteristic)): \(error)")
    #endif
    eventHandler?(.protocolEvent(session, .failed(characteristic, error)))
  }

  private func abort(_ link: Link, failure: WirelessFailure) {
    #if DEBUG
    observePairing?("BLE link aborted: \(failure)")
    #endif
    eventHandler?(.linkFailed(link.id, failure))
  }

  private func disconnected(_ central: CBCentralManager, peripheral: CBPeripheral, error: Error?) {
    guard let session = connections.consumeTerminal(manager: central, peripheral: peripheral)
    else { return }
    #if DEBUG
    observePairing?("BLE link ended \(Self.errorLabel(error))")
    #endif
    finishLink(session: session, failure: error.map(Self.failure) ?? .connectionLost)
  }

  private func finishLink(session: UUID, failure: WirelessFailure) {
    guard let active, active.id == session else { return }
    active.peripheral.delegate = nil
    self.active = nil
    eventHandler?(.disconnected(session, failure))
  }

  static func modelRead(_ data: Data?, error: Error?) -> Result<String?, WirelessFailure> {
    if let error {
      if let att = error as? CBATTError {
        switch att.code {
        case .attributeNotFound, .readNotPermitted, .requestNotSupported, .invalidHandle:
          return .success(nil)
        default:
          break
        }
      }
      return .failure(failure(from: error))
    }
    guard let data, data.count <= 64 else { return .success(nil) }
    let text = String(data: data.prefix { $0 != 0 }, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return .success(text.flatMap { $0.isEmpty ? nil : $0 })
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

  #if DEBUG
  private static func serviceLabel(_ uuid: CBUUID) -> String {
    guard let index = pairingServices.firstIndex(of: uuid) else { return "other service" }
    return ["secure pairing", "legacy pairing", "configuration", "network", "Wi-Fi launch", "Device Information"][index]
  }

  nonisolated private static func knownCharacteristicLabel(_ key: BLEGATTCharacteristic) -> String? {
    switch key.characteristic {
    case "2a24": "model"
    case "2a26": "firmware"
    case "f557d96b-8284-4667-8793-b971c1deca2a": "secure status"
    case "aba356eb-9633-4e60-b73f-f52516dbd671": "legacy pairing"
    case "85b9163e-62d1-49ff-a6f5-054b4630d4a1": "client identification"
    case "a68e3f66-0fcc-4395-8d4c-aa980b5877fa": "readiness indication"
    case "bd17ba04-b76b-4892-a545-b73ba1f74dae": "second indication"
    case "f9150137-5d40-4801-a8dc-f7fc5b01da50": "configuration notification"
    case "bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4": "network name"
    case "e809256a-915c-4967-92e8-53b7d4cad213": "network password"
    case "600655e6-3637-42f1-8fb2-44efc5c63b13": "Wi-Fi launch"
    case "75823784-fbb7-4b71-abae-cd9a34072e3c": "notification 5"
    case "e6692c5c-b7cd-44f4-95fc-eda07ce32560": "notification 6"
    case "aab609c4-94dd-4d89-bc60-665d5090b828": "notification 7"
    case "2a125640-706d-4dd1-b420-c0f4ab93c361": "notification 8"
    case "82a9f452-c5ce-4ef5-8203-3fc9a47f8171": "notification 9"
    case "deef7187-3f43-4364-9e22-11a8c8a15951": "notification 10"
    default: nil
    }
  }

  private static func characteristicLabel(_ key: BLEGATTCharacteristic) -> String {
    "\(serviceLabel(CBUUID(string: key.service)))/\(knownCharacteristicLabel(key) ?? "other characteristic")"
  }

  private static func errorLabel(_ error: Error?) -> String {
    guard let error else { return "succeeded" }
    if let error = error as? CBATTError { return "ATT error \(error.code.rawValue)" }
    if let error = error as? CBError { return "CoreBluetooth error \(error.code.rawValue)" }
    return "unclassified error"
  }
  #endif
}
