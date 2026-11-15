import Foundation
import Security

@MainActor
final class ProbeKeychain: CameraKeychain {
  var observe: ((String) -> Void)?

  func copy(_ query: [String: Any]) -> (OSStatus, Any?) {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    observe?("Keychain copy status \(status)")
    return (status, result)
  }

  func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    observe?("Keychain update status \(status)")
    return status
  }

  func add(_ attributes: [String: Any]) -> OSStatus {
    let status = SecItemAdd(attributes as CFDictionary, nil)
    observe?("Keychain add status \(status)")
    return status
  }

  func delete(_ query: [String: Any]) -> OSStatus {
    let status = SecItemDelete(query as CFDictionary)
    observe?("Keychain delete status \(status)")
    return status
  }
}
