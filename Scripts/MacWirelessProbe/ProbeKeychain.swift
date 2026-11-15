import Foundation
import Security

@MainActor
final class ProbeKeychain: CameraKeychain {
  var observe: ((String) -> Void)?

  func copy(_ query: [String: Any]) -> (OSStatus, Any?) {
    guard query[kSecClass as String] as? String == kSecClassGenericPassword as String,
      query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String,
      query[kSecReturnData as String] as? Bool == true
    else { return copyMatching(query, operation: "copy") }

    // The Mac file-based Keychain rejects requesting all password data at once.
    // Retain the original filters while enumerating and reading each item.
    var enumeration = query
    enumeration.removeValue(forKey: kSecReturnData as String)
    enumeration[kSecReturnPersistentRef as String] = true
    let (status, result) = copyMatching(enumeration, operation: "enumerate")
    guard status == errSecSuccess else { return (status, nil) }
    guard let references = result as? [Data] else { return (errSecDecode, nil) }

    var records: [Data] = []
    for reference in references {
      var item = query
      item[kSecMatchLimit as String] = kSecMatchLimitOne
      item[kSecValuePersistentRef as String] = reference
      let (status, result) = copyMatching(item, operation: "read item")
      if status == errSecItemNotFound { continue }
      guard status == errSecSuccess else { return (status, nil) }
      guard let data = result as? Data else { return (errSecDecode, nil) }
      records.append(data)
    }
    return (errSecSuccess, records)
  }

  private func copyMatching(_ query: [String: Any], operation: String) -> (OSStatus, Any?) {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    observe?("Keychain \(operation) status \(status)")
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
