import Foundation

/// Fujifilm PC AutoSave message roles from libfuji 3b9932a, docs/autosave.md
/// and lib/discovery.c. The text messages contain claims, not authenticated identity.
public enum AutoSaveCodec {
  public enum Phase: Sendable {
    case registration
    case transfer

    /// Camera discovery is UDP and the return invitation is TCP on this port.
    public var port: UInt16 { self == .registration ? 51542 : 51541 }
  }

  public struct Invitation: Sendable {
    public let cameraName: String
    public let cameraModel: String?
  }

  public static let notifyPort: UInt16 = 51540
  public static let commandPort: UInt16 = 55740
  public static let maximumMessageBytes = 1024
  private static let service = "PCAUTOSAVE/1.0"
  private static let folder = "guest"

  public static func discovery(_ data: Data, phase: Phase, source: String) throws -> String {
    let fields: Set<String> = ["mx", "host", "dscaddr", "service"]
    guard let (firstLine, headers) = try message(data, allowed: fields),
      Set(headers.keys) == fields
    else { throw WirelessFailure.malformedData }
    let words = firstLine.split(separator: " ", omittingEmptySubsequences: false)
    guard words.count == 3, words[0] == "DISCOVER", words[2] == "HTTP/1.1",
      let wait = headers["mx"].flatMap(UInt8.init), (1...5).contains(wait),
      let host = headers["host"], host.hasSuffix(":|"),
      ipv4(String(host.dropLast(2))) != nil,
      headers["service"] == service,
      let address = headers["dscaddr"], isUnicast(address)
    else { throw WirelessFailure.malformedData }
    guard address == source else { throw WirelessFailure.peerMismatch }
    let importer = String(words[1])
    guard phase == .registration ? importer == "*" : isImporter(importer) else {
      throw WirelessFailure.malformedData
    }
    return importer
  }

  public static func notify(address: String, importer: String) throws -> Data {
    guard isUnicast(address), isImporter(importer) else { throw WirelessFailure.malformedData }
    return wire(["NOTIFY * HTTP/1.1", "HOST: \(address):\(notifyPort)", "IMPORTER: \(importer)"])
  }

  public static func notifyAcknowledged(_ data: Data) throws -> Bool {
    guard let (firstLine, _) = try message(data, allowed: []) else { return false }
    guard firstLine == "HTTP/1.1 200 OK" else { throw WirelessFailure.authentication }
    return true
  }

  /// Pinned messages can end with one CRLF rather than an empty HTTP header line.
  /// A caller buffers until all required lines are complete.
  public static func invitation(_ data: Data, phase: Phase, localAddress: String) throws -> Invitation? {
    let fields: Set<String> = ["host", "dscname", phase == .registration ? "dscmodel" : "dscport"]
    guard let (firstLine, headers) = try message(data, allowed: fields) else { return nil }
    let target = phase == .registration ? "REGISTER *" : "IMPORT /\(folder)"
    guard firstLine == "\(target) HTTP/1.1" else { throw WirelessFailure.malformedData }
    guard Set(headers.keys) == fields else { return nil }
    guard isUnicast(localAddress), headers["host"] == "\(localAddress):\(phase.port)",
      let name = headers["dscname"], name.utf8.count <= 128
    else { throw WirelessFailure.malformedData }
    switch phase {
    case .registration:
      guard let model = headers["dscmodel"], model.utf8.count <= 32 else {
        throw WirelessFailure.malformedData
      }
      return Invitation(cameraName: name, cameraModel: model)
    case .transfer:
      // The command connection uses the pinned command port. This claim cannot reroute it.
      guard headers["dscport"] == "\\" || headers["dscport"].flatMap(UInt16.init).map({ $0 != 0 }) == true else {
        throw WirelessFailure.malformedData
      }
      return Invitation(cameraName: name, cameraModel: nil)
    }
  }

  public static func response(to phase: Phase) -> Data {
    let status = "HTTP/1.1 200 OK"
    return phase == .registration
      ? wire([status, "FOLDER: \(folder)", "ServiceName: \(service)"])
      : wire([status])
  }

  private static func message(_ data: Data, allowed: Set<String>) throws -> (String, [String: String])? {
    guard data.count <= maximumMessageBytes,
      data.allSatisfy({ (0x20...0x7e).contains($0) || $0 == 0x0d || $0 == 0x0a })
    else { throw WirelessFailure.malformedData }
    let text = String(decoding: data, as: UTF8.self)
    guard text.hasSuffix("\r\n") else { return nil }
    var lines = String(decoding: data.dropLast(2), as: UTF8.self).components(separatedBy: "\r\n")
    if lines.last == "" { lines.removeLast() }
    guard let first = lines.first, !first.isEmpty, !first.contains("\r"), !first.contains("\n") else {
      throw WirelessFailure.malformedData
    }
    var fields: [String: String] = [:]
    for line in lines.dropFirst() {
      guard !line.contains("\r"), !line.contains("\n"),
        let colon = line.firstIndex(of: ":") else { throw WirelessFailure.malformedData }
      let key = line[..<colon].lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard allowed.contains(key), fields[key] == nil, !value.isEmpty else {
        throw WirelessFailure.malformedData
      }
      fields[key] = value
    }
    return (first, fields)
  }

  private static func wire(_ lines: [String]) -> Data {
    Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
  }

  private static func isImporter(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
      (0x30...0x39).contains($0) || (0x41...0x5a).contains($0) || (0x61...0x7a).contains($0)
        || $0 == 0x2d || $0 == 0x5f
    }
  }

  private static func ipv4(_ value: String) -> [UInt8]? {
    let components = value.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 4 else { return nil }
    let octets = components.compactMap { component -> UInt8? in
      guard let octet = UInt8(component), String(octet) == component else { return nil }
      return octet
    }
    return octets.count == 4 ? octets : nil
  }

  private static func isUnicast(_ value: String) -> Bool {
    guard let first = ipv4(value)?.first else { return false }
    return first > 0 && first < 224 && first != 127
  }
}
