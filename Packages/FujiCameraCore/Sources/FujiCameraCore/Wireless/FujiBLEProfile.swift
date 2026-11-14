import Foundation

public protocol FujiBLEProfile: Sendable {
  mutating func receive(_ event: BLEProtocolEvent) throws -> [BLEProtocolAction]
}

public struct BLEGATTCharacteristic: Hashable, Sendable {
  public let service: String
  public let characteristic: String

  public init(service: String, characteristic: String) {
    self.service = Self.canonicalUUID(service)
    self.characteristic = Self.canonicalUUID(characteristic)
  }

  private static func canonicalUUID(_ uuid: String) -> String {
    let uuid = uuid.lowercased()
    if uuid.hasPrefix("0000"), uuid.hasSuffix("-0000-1000-8000-00805f9b34fb"),
      uuid.utf8.count == 36
    {
      return String(uuid.dropFirst(4).prefix(4))
    }
    return uuid
  }
}

public enum BLEProtocolEvent: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  case services(Set<BLEGATTCharacteristic>)
  case read(BLEGATTCharacteristic, Data)
  case wrote(BLEGATTCharacteristic)
  case subscribed(BLEGATTCharacteristic)
  case subscriptionUnavailable(BLEGATTCharacteristic)
  case notification(BLEGATTCharacteristic, Data)
  case failed(BLEGATTCharacteristic, WirelessFailure)
  case activateWiFi

  public var description: String { "BLEProtocolEvent" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }

  /// The maximum value length for an ATT attribute.
  public static let maximumAttributeBytes = 512
}

public enum BLEWritePurpose: Equatable, Sendable {
  case pair
  case authenticate
  case identify
  case activateWiFi
}

public enum BLEProtocolAction: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  case read(BLEGATTCharacteristic)
  case write(BLEGATTCharacteristic, Data, BLEWritePurpose)
  case subscribe(BLEGATTCharacteristic)
  case authenticated(firmware: String?)
  case wifiReady(BLEWiFiCredentials)

  public var description: String {
    switch self {
    case .read: "BLE read"
    case .write(_, _, let purpose): "BLE write (\(purpose))"
    case .subscribe: "BLE subscribe"
    case .authenticated: "BLE authenticated"
    case .wifiReady: "BLE WiFi ready"
    }
  }

  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
}

public struct BLEWiFiCredentials: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let ssid: String
  public let password: String

  public init(ssid: String, password: String) {
    self.ssid = ssid
    self.password = password
  }

  public var description: String { "[redacted WiFi credentials]" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
}

enum FujiBLEGATT {
  static let securePair = "123d8f06-62a1-4935-9322-833c531ee225"
  static let legacyPair = "91f1de68-dff6-466e-8b65-ff13b0f16fb8"
  static let identification = "85b9163e-62d1-49ff-a6f5-054b4630d4a1"
  static let configuration = "4c0020fe-f3b6-40de-acc9-77d129067b14"
  static let network = "4e941240-d01d-46b9-a5ea-67636806830b"
  static let readiness = BLEGATTCharacteristic(
    service: configuration, characteristic: "a68e3f66-0fcc-4395-8d4c-aa980b5877fa")
  static let secondIndication = BLEGATTCharacteristic(
    service: configuration, characteristic: "bd17ba04-b76b-4892-a545-b73ba1f74dae")
  static let configurationNotification = BLEGATTCharacteristic(
    service: configuration, characteristic: "f9150137-5d40-4801-a8dc-f7fc5b01da50")
  static let ssid = BLEGATTCharacteristic(
    service: network, characteristic: "bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4")
  static let password = BLEGATTCharacteristic(
    service: network, characteristic: "e809256a-915c-4967-92e8-53b7d4cad213")
  static let launch = BLEGATTCharacteristic(
    service: "6514eb81-4e8f-458d-aa2a-e691336cdfac",
    characteristic: "600655e6-3637-42f1-8fb2-44efc5c63b13")
  static let firmware = BLEGATTCharacteristic(service: "180a", characteristic: "2a26")
}

struct FujiBLEHandshake: Sendable {
  enum Method: Sendable {
    case secure(status: BLEGATTCharacteristic)
    case token(BLEGATTCharacteristic, WirelessProtocolPeerKey, BLEWritePurpose)

    var characteristic: BLEGATTCharacteristic {
      switch self {
      case .secure(let status): status
      case .token(let token, _, _): token
      }
    }
  }

  private enum Stage: Sendable {
    case waitingForServices
    case readStatus
    case writeAuthentication
    case identify
    case readSSID
    case subscribe(ArraySlice<BLEGATTCharacteristic>)
    case readFirmware
    case authenticated
    case readPassword
    case launchWiFi(password: String, earlyStatus: UInt8?)
    case waitForWiFi(password: String)
    case failed
  }

  let method: Method
  let subscriptions: [BLEGATTCharacteristic]
  private var stage = Stage.waitingForServices
  private var characteristics: Set<BLEGATTCharacteristic> = []
  private var networkSSID: String?

  private var identification: BLEGATTCharacteristic {
    BLEGATTCharacteristic(
      service: method.characteristic.service, characteristic: FujiBLEGATT.identification)
  }

  init(method: Method, subscriptions: [BLEGATTCharacteristic]) {
    self.method = method
    self.subscriptions = subscriptions
  }

  mutating func receive(_ event: BLEProtocolEvent) throws -> [BLEProtocolAction] {
    do {
      return try advance(event)
    } catch {
      stage = .failed
      throw error
    }
  }

  private mutating func advance(_ event: BLEProtocolEvent) throws -> [BLEProtocolAction] {
    typealias GATT = FujiBLEGATT
    switch (stage, event) {
    case (.waitingForServices, .services(let discovered)):
      let required: Set = [method.characteristic, identification, GATT.readiness]
      guard required.isSubset(of: discovered) else { throw WirelessFailure.unsupportedProtocol }
      characteristics = discovered
      switch method {
      case .secure(let status):
        stage = .readStatus
        return [.read(status)]
      case .token(let characteristic, let token, let purpose):
        guard token.bytes.count == 4 else { throw WirelessFailure.authentication }
        stage = .writeAuthentication
        return [.write(characteristic, token.bytes, purpose)]
      }

    case (.readStatus, .read(let characteristic, let bytes)) where characteristic == method.characteristic:
      guard bytes.count == 4 else { throw WirelessFailure.malformedData }
      stage = .writeAuthentication
      return [.write(characteristic, Data(bytes.prefix(3)) + Data([0x20]), .authenticate)]

    case (.writeAuthentication, .wrote(let characteristic)) where characteristic == method.characteristic:
      stage = .identify
      return [.write(identification, Data("Fuji Studio".utf8), .identify)]

    case (.identify, .wrote(let characteristic)) where characteristic == identification:
      if characteristics.contains(GATT.ssid) {
        stage = .readSSID
        return [.read(GATT.ssid)]
      }
      return subscribe(to: subscriptions.filter(characteristics.contains)[...])

    case (.readSSID, .read(GATT.ssid, let bytes)):
      networkSSID = Self.text(bytes, length: 1...32)
      return subscribe(to: subscriptions.filter(characteristics.contains)[...])

    case (.readSSID, .failed(GATT.ssid, .unsupportedProtocol)):
      return subscribe(to: subscriptions.filter(characteristics.contains)[...])

    case (.subscribe(let remaining), .subscribed(let characteristic))
    where characteristic == remaining.first:
      return subscribe(to: remaining.dropFirst())

    case (.subscribe(let remaining), .subscriptionUnavailable(let characteristic))
    where characteristic == remaining.first:
      guard characteristic != GATT.readiness else { throw WirelessFailure.unsupportedProtocol }
      return subscribe(to: remaining.dropFirst())

    case (.readFirmware, .read(GATT.firmware, let bytes)):
      return authenticated(firmware: Self.text(bytes, length: 1...64))
    case (.readFirmware, .failed(GATT.firmware, .unsupportedProtocol)):
      return authenticated(firmware: nil)

    case (.authenticated, .activateWiFi):
      let required: Set = [GATT.ssid, GATT.password, GATT.launch]
      guard required.isSubset(of: characteristics) else { throw WirelessFailure.unsupportedProtocol }
      guard networkSSID != nil else { throw WirelessFailure.malformedData }
      stage = .readPassword
      return [.read(GATT.password)]

    case (.readPassword, .read(GATT.password, let bytes)):
      guard let password = Self.text(bytes, length: 8...63) else {
        throw WirelessFailure.malformedData
      }
      stage = .launchWiFi(password: password, earlyStatus: nil)
      return [.write(GATT.launch, Data([0x04, 0x00]), .activateWiFi)]

    case (.launchWiFi(let password, let earlyStatus), .wrote(GATT.launch)):
      return try acceptWiFiStatus(earlyStatus, password: password)

    case (.launchWiFi(let password, nil), .notification(GATT.readiness, let bytes)):
      if let status = Self.wifiStatus(bytes) {
        stage = .launchWiFi(password: password, earlyStatus: status)
      }
      return []

    case (.waitForWiFi(let password), .notification(GATT.readiness, let bytes)):
      return try acceptWiFiStatus(Self.wifiStatus(bytes), password: password)

    case (.failed, _):
      return []
    case (_, .notification(GATT.ssid, let bytes)):
      networkSSID = Self.text(bytes, length: 1...32)
      return []
    case (_, .failed(_, let failure)):
      throw failure
    default:
      return []
    }
  }

  private mutating func subscribe(
    to remaining: ArraySlice<BLEGATTCharacteristic>
  ) -> [BLEProtocolAction] {
    if let next = remaining.first {
      stage = .subscribe(remaining)
      return [.subscribe(next)]
    }
    if characteristics.contains(FujiBLEGATT.firmware) {
      stage = .readFirmware
      return [.read(FujiBLEGATT.firmware)]
    }
    return authenticated(firmware: nil)
  }

  private mutating func authenticated(firmware: String?) -> [BLEProtocolAction] {
    stage = .authenticated
    return [.authenticated(firmware: firmware)]
  }

  private static func wifiStatus(_ bytes: Data) -> UInt8? {
    // Libfuji examines the first byte. The second byte is undocumented.
    guard (1...2).contains(bytes.count), let status = bytes.first, status <= 1 else { return nil }
    return status
  }

  private mutating func acceptWiFiStatus(_ status: UInt8?, password: String) throws
    -> [BLEProtocolAction]
  {
    if status == 0 { throw WirelessFailure.cameraBusy }
    guard status == 1 else {
      stage = .waitForWiFi(password: password)
      return []
    }
    guard let ssid = networkSSID else { throw WirelessFailure.malformedData }
    stage = .authenticated
    return [.wifiReady(BLEWiFiCredentials(ssid: ssid, password: password))]
  }

  private static func text(_ bytes: Data, length: ClosedRange<Int>) -> String? {
    guard bytes.count <= BLEProtocolEvent.maximumAttributeBytes else { return nil }
    let value = bytes.prefix(while: { $0 != 0 })
    guard length.contains(value.count), bytes.dropFirst(value.count).allSatisfy({ $0 == 0 }),
      let text = String(data: value, encoding: .utf8),
      text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return text
  }
}
