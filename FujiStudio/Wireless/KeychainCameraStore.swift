import Foundation
import FujiCameraCore
import Security

@MainActor
protocol CameraKeychain {
  func copy(_ query: [String: Any]) -> (OSStatus, Any?)
  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
  func add(_ attributes: [String: Any]) -> OSStatus
  func delete(_ query: [String: Any]) -> OSStatus
}

private struct SecurityCameraKeychain: CameraKeychain {
  func copy(_ query: [String: Any]) -> (OSStatus, Any?) {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return (status, result)
  }

  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
    SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
  }

  func add(_ attributes: [String: Any]) -> OSStatus {
    SecItemAdd(attributes as CFDictionary, nil)
  }

  func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

/// Each camera and its secrets share one device-local record, so replacing or
/// forgetting it cannot leave a token or password in a separate item.
@MainActor
final class KeychainCameraStore: CameraPairingStore, CameraNetworkCredentialProvider {
  private struct Password: Codable {
    let reference: CameraCredentialReference
    let value: String
  }

  private struct Record: Codable {
    var camera: SavedCamera
    var peerKey: Data?
    var wifi: Password?
  }

  private let service: String
  private let defaults: UserDefaults
  private let keychain: any CameraKeychain
  private let selectionKey = "wireless.selectedCameraID"

  init(
    defaults: UserDefaults = .standard, service: String = "com.lun3x.FujiStudio.camera",
    keychain: (any CameraKeychain)? = nil
  ) {
    self.defaults = defaults
    self.service = service
    self.keychain = keychain ?? SecurityCameraKeychain()
  }

  func cameras() async throws -> [SavedCamera] {
    var query = baseQuery
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    query[kSecReturnData as String] = true

    let (status, result) = keychain.copy(query)
    if status == errSecItemNotFound { return [] }
    try check(status)
    guard let items = result as? [Data] else { throw WirelessFailure.malformedData }
    return try items.map { try decode($0).camera }.sorted {
      if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
      return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
    }
  }

  func selected() async throws -> WirelessCameraID? {
    guard let value = defaults.string(forKey: selectionKey), let uuid = UUID(uuidString: value)
    else { return nil }
    let id = WirelessCameraID(rawValue: uuid)
    guard try record(for: id) != nil else {
      defaults.removeObject(forKey: selectionKey)
      return nil
    }
    return id
  }

  func save(_ camera: SavedCamera) async throws {
    if var existing = try record(for: camera.id) {
      guard existing.camera.peripheralID == camera.peripheralID, existing.camera.model == camera.model,
        existing.camera.peerKeyReference == camera.peerKeyReference
      else { throw WirelessFailure.peerMismatch }
      existing.camera = camera
      try write(existing)
    } else {
      guard camera.peerKeyReference == nil else { throw WirelessFailure.authentication }
      try write(Record(camera: camera))
    }
  }

  func select(_ id: WirelessCameraID) async throws {
    guard try record(for: id) != nil else { throw WirelessFailure.peerMismatch }
    defaults.set(id.rawValue.uuidString, forKey: selectionKey)
  }

  func forget(_ id: WirelessCameraID) async throws {
    let status = keychain.delete(query(for: id))
    if status != errSecItemNotFound { try check(status) }
    if defaults.string(forKey: selectionKey) == id.rawValue.uuidString {
      defaults.removeObject(forKey: selectionKey)
    }
  }

  func savePaired(_ camera: SavedCamera, peerKey: WirelessProtocolPeerKey?) throws -> SavedCamera {
    var camera = camera
    camera.peerKeyReference = peerKey.map { _ in
      CameraCredentialReference(cameraID: camera.id, version: UUID())
    }
    try write(Record(camera: camera, peerKey: peerKey?.bytes))
    return camera
  }

  func peerKey(for camera: SavedCamera) throws -> WirelessProtocolPeerKey? {
    guard let record = try record(for: camera.id) else { return nil }
    guard record.camera.peripheralID == camera.peripheralID, record.camera.model == camera.model,
      record.camera.peerKeyReference == camera.peerKeyReference
    else { throw WirelessFailure.peerMismatch }
    return record.peerKey.map(WirelessProtocolPeerKey.init(bytes:))
  }

  func savePassword(_ password: String, for id: WirelessCameraID) throws -> CameraCredentialReference {
    guard var record = try record(for: id) else { throw WirelessFailure.peerMismatch }
    let reference = CameraCredentialReference(cameraID: id, version: UUID())
    record.wifi = Password(reference: reference, value: password)
    try write(record)
    return reference
  }

  func password(for reference: CameraCredentialReference) async throws -> String {
    guard let wifi = try record(for: reference.cameraID)?.wifi,
      wifi.reference == reference
    else { throw WirelessFailure.authentication }
    return wifi.value
  }

  private var baseQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrSynchronizable as String: false,
    ]
  }

  private func query(for id: WirelessCameraID) -> [String: Any] {
    var query = baseQuery
    query[kSecAttrAccount as String] = id.rawValue.uuidString
    return query
  }

  private func record(for id: WirelessCameraID) throws -> Record? {
    var query = query(for: id)
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    query[kSecReturnData as String] = true

    let (status, result) = keychain.copy(query)
    if status == errSecItemNotFound { return nil }
    try check(status)
    guard let data = result as? Data else { throw WirelessFailure.malformedData }
    return try decode(data)
  }

  private func decode(_ data: Data) throws -> Record {
    do {
      return try JSONDecoder().decode(Record.self, from: data)
    } catch {
      throw WirelessFailure.malformedData
    }
  }

  private func write(_ record: Record) throws {
    let data = try JSONEncoder().encode(record)
    let query = query(for: record.camera.id)
    let attributes: [String: Any] = [
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      kSecValueData as String: data,
    ]
    let status = keychain.update(query, attributes: attributes)
    if status == errSecItemNotFound {
      try check(keychain.add(query.merging(attributes) { _, new in new }))
    } else {
      try check(status)
    }
  }

  private func check(_ status: OSStatus) throws {
    guard status == errSecSuccess else { throw WirelessFailure.unavailableStorage }
  }
}
