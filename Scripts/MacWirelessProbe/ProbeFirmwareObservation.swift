import Foundation

enum ProbeFirmwareObservation {
  static func label(_ firmware: String?) -> String {
    guard let firmware else { return "unavailable" }
    guard firmware.utf8.count <= 16 else { return "tooLong" }
    guard firmware.utf8.allSatisfy({ (0x20...0x7e).contains($0) }) else {
      return "nonPrintableASCII"
    }

    var version = firmware.trimmingCharacters(in: .whitespaces)
    if version.hasPrefix("Ver.") {
      version = version.dropFirst(4).trimmingCharacters(in: .whitespaces)
    }

    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    guard (2...3).contains(parts.count), parts.allSatisfy({ part in
      (1...3).contains(part.utf8.count) && part.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }) else { return "invalidFormat" }
    return version
  }
}
