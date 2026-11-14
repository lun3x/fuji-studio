import Foundation
import FujiCameraCore
import Security
import XCTest

@testable import FujiStudio

@MainActor
final class SavedCameraStoreTests: XCTestCase {
  func testRelaunchAndForgetOnlyTargetProtectedRecord() async throws {
    let namespace = "FujiStudio.Tests.CameraStore.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
    defer { defaults.removePersistentDomain(forName: namespace) }
    let keychain = ReplayCameraKeychain(service: namespace)
    let store = KeychainCameraStore(defaults: defaults, service: namespace, keychain: keychain)
    let existingReceipt = "receipt-for-a-capture"
    defaults.set(existingReceipt, forKey: "existing-receipt-fixture")

    let xt5 = SavedCamera(
      id: WirelessCameraID(), peripheralID: UUID(), model: .xt5, displayName: "Office camera")
    let xe3 = SavedCamera(
      id: WirelessCameraID(), peripheralID: UUID(), model: .xe3, displayName: "Travel camera")
    try await store.save(xt5)
    let token = WirelessProtocolPeerKey(bytes: Data([0xda, 0x10, 0x5f, 0x9c]))
    let paired = try store.savePaired(xe3, peerKey: token)
    let xe3Credential = try store.savePassword("test-private-wifi-password", for: paired.id)
    let xt5Credential = try store.savePassword("test-xt5-wifi-password", for: xt5.id)
    try await store.select(paired.id)

    let relaunched = KeychainCameraStore(
      defaults: try XCTUnwrap(UserDefaults(suiteName: namespace)), service: namespace,
      keychain: keychain)
    let cameras = try await relaunched.cameras()
    let selected = try await relaunched.selected()
    XCTAssertEqual(Set(cameras.map(\.id)), Set([xt5.id, paired.id]))
    XCTAssertEqual(selected, paired.id)
    XCTAssertEqual(try relaunched.peerKey(for: paired), token)
    let password = try await relaunched.password(for: xe3Credential)
    XCTAssertEqual(password, "test-private-wifi-password")
    XCTAssertFalse(
      String(reflecting: defaults.persistentDomain(forName: namespace)).contains("wifi-password"))

    try await relaunched.forget(paired.id)
    let remaining = try await relaunched.cameras()
    let selectionAfterForget = try await relaunched.selected()
    XCTAssertEqual(remaining, [xt5])
    XCTAssertNil(selectionAfterForget)
    XCTAssertNil(try relaunched.peerKey(for: paired))
    do {
      _ = try await relaunched.password(for: xe3Credential)
      XCTFail("Forgotten camera's password was readable")
    } catch {
      XCTAssertEqual(error as? WirelessFailure, .authentication)
    }
    let remainingPassword = try await relaunched.password(for: xt5Credential)
    XCTAssertEqual(remainingPassword, "test-xt5-wifi-password")
    XCTAssertEqual(defaults.string(forKey: "existing-receipt-fixture"), existingReceipt)
  }
}

/// Models the system storage boundary for unsigned simulator builds.
@MainActor
final class ReplayCameraKeychain: CameraKeychain {
  private let service: String
  private var items: [String: Data] = [:]

  init(service: String) {
    self.service = service
  }

  func copy(_ query: [String: Any]) -> (OSStatus, Any?) {
    validate(query)
    XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
    if let account = query[kSecAttrAccount as String] as? String {
      guard let data = items[account] else { return (errSecItemNotFound, nil) }
      XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
      return (errSecSuccess, data)
    }
    XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitAll as String)
    return items.isEmpty ? (errSecItemNotFound, nil) : (errSecSuccess, Array(items.values))
  }

  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
    validate(query)
    guard let account = query[kSecAttrAccount as String] as? String else { return errSecParam }
    guard items[account] != nil else { return errSecItemNotFound }
    return save(attributes, account: account)
  }

  func add(_ attributes: [String: Any]) -> OSStatus {
    validate(attributes)
    guard let account = attributes[kSecAttrAccount as String] as? String else { return errSecParam }
    guard items[account] == nil else { return errSecDuplicateItem }
    return save(attributes, account: account)
  }

  func delete(_ query: [String: Any]) -> OSStatus {
    validate(query)
    guard let account = query[kSecAttrAccount as String] as? String else { return errSecParam }
    return items.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
  }

  private func validate(_ query: [String: Any]) {
    XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
    XCTAssertEqual(query[kSecAttrService as String] as? String, service)
    XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
  }

  private func save(_ attributes: [String: Any], account: String) -> OSStatus {
    XCTAssertEqual(
      attributes[kSecAttrAccessible as String] as? String,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
    items[account] = data
    return errSecSuccess
  }
}
