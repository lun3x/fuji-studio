import Foundation
import FujiCameraCore
import Security

@main
@MainActor
private struct KeychainTests {
  enum Failure: Error {
    case unexpectedRecords
    case missingSelection
    case cleanupFailed
  }

  static func main() async {
    do {
      try await validate()
      print("Mac Keychain enumeration and persisted selection checks passed.")
    } catch {
      print("FAIL: \(error)")
      exit(1)
    }
  }

  private static func validate() async throws {
    let service = "com.lun3x.FujiStudio.MacWirelessProbe.tests.\(UUID())"
    let otherService = "\(service).isolated"
    let defaults = UserDefaults(suiteName: service)!
    let keychain = ProbeKeychain()
    keychain.observe = { print($0) }
    let store = KeychainCameraStore(defaults: defaults, service: service, keychain: keychain)
    let otherStore = KeychainCameraStore(defaults: defaults, service: otherService, keychain: keychain)
    let first = SavedCamera(id: WirelessCameraID(), peripheralID: UUID(), model: .xt5, displayName: "A")
    let second = SavedCamera(id: WirelessCameraID(), peripheralID: UUID(), model: .xt5, displayName: "B")
    let other = SavedCamera(id: first.id, peripheralID: UUID(), model: .xe3, displayName: "Isolated")
    defer {
      removeTestRecord(first, service: service)
      removeTestRecord(second, service: service)
      removeTestRecord(other, service: otherService)
      defaults.removePersistentDomain(forName: service)
    }

    guard try await store.cameras().isEmpty else { throw Failure.unexpectedRecords }
    _ = try store.savePaired(first, peerKey: nil)
    _ = try store.savePaired(second, peerKey: nil)
    _ = try otherStore.savePaired(other, peerKey: nil)
    guard try await store.cameras() == [first, second], try await otherStore.cameras() == [other] else {
      throw Failure.unexpectedRecords
    }

    try await store.select(second.id)
    let reloaded = KeychainCameraStore(defaults: defaults, service: service, keychain: keychain)
    guard try await reloaded.selected() == second.id, try reloaded.peerKey(for: second) == nil else {
      throw Failure.missingSelection
    }

    try await reloaded.forget(first.id)
    try await reloaded.forget(second.id)
    try await otherStore.forget(other.id)
    guard try await reloaded.cameras().isEmpty, try await reloaded.selected() == nil,
      try await otherStore.cameras().isEmpty
    else { throw Failure.cleanupFailed }
  }

  private static func removeTestRecord(_ camera: SavedCamera, service: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: camera.id.rawValue.uuidString,
      kSecAttrSynchronizable as String: false,
    ]
    let status = SecItemDelete(query as CFDictionary)
    if status != errSecSuccess && status != errSecItemNotFound {
      print("Synthetic record cleanup status \(status)")
    }
  }
}
