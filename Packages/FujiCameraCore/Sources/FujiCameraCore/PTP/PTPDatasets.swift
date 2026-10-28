import CryptoKit
import Foundation

/// Standard PTP grammar only. Vendor look mappings require observed X-T5 fixtures.
public enum PTPDatasetError: Error, Sendable, Equatable {
  case truncated, oversized, trailingBytes, invalidString, wrongProperty, invalidAccess, invalidForm
  case unsupportedDataType(UInt16)
  case unsupportedCamera, missingReadOperations
}

public struct FujiDeviceInfo: Sendable, Equatable {
  public let standardVersion: UInt16
  public let vendorExtensionID: UInt32
  public let vendorExtensionVersion: UInt16
  public let functionalMode: UInt16
  public let operations: [UInt16]
  public let events: [UInt16]
  public let properties: [UInt16]
  public let captureFormats: [UInt16]
  public let imageFormats: [UInt16]
  public let manufacturer: String
  public let model: String
  public let firmware: String
  public init(
    standardVersion: UInt16, vendorExtensionID: UInt32, vendorExtensionVersion: UInt16,
    functionalMode: UInt16, operations: [UInt16], events: [UInt16], properties: [UInt16],
    captureFormats: [UInt16], imageFormats: [UInt16], manufacturer: String, model: String,
    firmware: String
  ) {
    self.standardVersion = standardVersion
    self.vendorExtensionID = vendorExtensionID
    self.vendorExtensionVersion = vendorExtensionVersion
    self.functionalMode = functionalMode
    self.operations = operations
    self.events = events
    self.properties = properties
    self.captureFormats = captureFormats
    self.imageFormats = imageFormats
    self.manufacturer = manufacturer
    self.model = model
    self.firmware = firmware
  }

  // Serial number and vendor description are deliberately discarded at the parser boundary.
}

public struct PTPPropertyValue: Sendable, Equatable {
  public let raw: Data
  public let string: String?
  /// Callers must establish an unsigned scalar data type before interpreting these bits.
  public var unsignedInteger: UInt64? {
    guard string == nil, [1, 2, 4, 8].contains(raw.count) else { return nil }
    return raw.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
  }
  public init(raw: Data, string: String? = nil) {
    self.raw = raw
    self.string = string
  }

}

public enum PTPPropertyForm: Sendable, Equatable {
  case none
  case range(minimum: PTPPropertyValue, maximum: PTPPropertyValue, step: PTPPropertyValue)
  case enumeration([PTPPropertyValue])
}

public struct PTPPropertyDescriptor: Sendable, Equatable {
  public let code: UInt16
  public let dataType: UInt16
  public let writable: Bool
  public let factoryDefault: PTPPropertyValue
  public let current: PTPPropertyValue
  public let form: PTPPropertyForm
  public init(
    code: UInt16, dataType: UInt16, writable: Bool, factoryDefault: PTPPropertyValue,
    current: PTPPropertyValue, form: PTPPropertyForm
  ) {
    self.code = code
    self.dataType = dataType
    self.writable = writable
    self.factoryDefault = factoryDefault
    self.current = current
    self.form = form
  }

}

public enum PTPDatasets {
  public static func deviceInfo(_ data: Data) throws -> FujiDeviceInfo {
    var reader = try Reader(data)
    let standard = try reader.u16()
    let vendor = try reader.u32()
    let version = try reader.u16()
    _ = try reader.string()
    let mode = try reader.u16()
    let operations = try reader.words()
    let events = try reader.words()
    let properties = try reader.words()
    let capture = try reader.words()
    let images = try reader.words()
    let manufacturer = try reader.string()
    let model = try reader.string()
    let firmware = try reader.string()
    _ = try reader.string()  // Do not retain serial, including in debug descriptions.
    try reader.finish()
    return FujiDeviceInfo(
      standardVersion: standard, vendorExtensionID: vendor, vendorExtensionVersion: version,
      functionalMode: mode, operations: operations, events: events, properties: properties,
      captureFormats: capture, imageFormats: images, manufacturer: manufacturer, model: model,
      firmware: firmware)
  }

  public static func propertyDescriptor(_ data: Data, expectedCode: UInt16) throws
    -> PTPPropertyDescriptor
  {
    var reader = try Reader(data)
    let code = try reader.u16()
    let type = try reader.u16()
    let access = try reader.u8()
    guard code == expectedCode else { throw PTPDatasetError.wrongProperty }
    guard access <= 1 else { throw PTPDatasetError.invalidAccess }
    let factory = try reader.value(type)
    let current = try reader.value(type)
    let form: PTPPropertyForm
    switch try reader.u8() {
    case 0: form = .none
    case 1:
      guard (1...10).contains(type) else { throw PTPDatasetError.invalidForm }
      form = try .range(
        minimum: reader.value(type), maximum: reader.value(type), step: reader.value(type))
    case 2:
      let count = Int(try reader.u16())
      guard count <= 4096 else { throw PTPDatasetError.oversized }
      var values: [PTPPropertyValue] = []
      for _ in 0..<count { values.append(try reader.value(type)) }
      form = .enumeration(values)
    default: throw PTPDatasetError.invalidForm
    }
    try reader.finish()
    return PTPPropertyDescriptor(
      code: code, dataType: type, writable: access == 1, factoryDefault: factory, current: current,
      form: form)
  }

  public static func value(_ data: Data, type: UInt16) throws -> PTPPropertyValue {
    var reader = try Reader(data)
    let value = try reader.value(type)
    try reader.finish()
    return value
  }

  private struct Reader {
    let data: Data
    var offset = 0
    init(_ data: Data) throws {
      guard data.count <= 65_536 else { throw PTPDatasetError.oversized }
      self.data = Data(data)  // Normalize slices to zero-based indices.
    }
    mutating func bytes(_ count: Int) throws -> Data {
      guard count >= 0, count <= data.count - offset else { throw PTPDatasetError.truncated }
      defer { offset += count }
      return data.subdata(in: offset..<(offset + count))
    }
    mutating func u8() throws -> UInt8 { try bytes(1)[0] }
    mutating func u16() throws -> UInt16 {
      let b = try bytes(2)
      return UInt16(b[0]) | UInt16(b[1]) << 8
    }
    mutating func u32() throws -> UInt32 {
      let b = try bytes(4)
      return b.enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) }
    }
    mutating func words() throws -> [UInt16] {
      let count = Int(try u32())
      guard count <= 4096 else { throw PTPDatasetError.oversized }
      guard count <= (data.count - offset) / 2 else { throw PTPDatasetError.truncated }
      var values: [UInt16] = []
      for _ in 0..<count { values.append(try u16()) }
      return values
    }
    mutating func string() throws -> String {
      let count = Int(try u8())
      if count == 0 { return "" }
      let units = try bytes(count * 2)
      guard units.suffix(2) == Data([0, 0]) else { throw PTPDatasetError.invalidString }
      for position in stride(from: 0, to: units.count - 2, by: 2) {
        guard units[position] != 0 || units[position + 1] != 0 else {
          throw PTPDatasetError.invalidString
        }
      }
      guard let text = String(data: units.dropLast(2), encoding: .utf16LittleEndian) else {
        throw PTPDatasetError.invalidString
      }
      return text
    }
    mutating func value(_ type: UInt16) throws -> PTPPropertyValue {
      let start = offset
      var text: String?
      if type == 0xffff {
        text = try string()
      } else {
        let array = (0x4001...0x400a).contains(type)
        let scalar = array ? type - 0x4000 : type
        guard (1...10).contains(scalar) else { throw PTPDatasetError.unsupportedDataType(type) }
        let width = 1 << Int((scalar - 1) / 2)
        let count = array ? Int(try u32()) : 1
        guard count <= 4096 else { throw PTPDatasetError.oversized }
        _ = try bytes(count * width)
      }
      return PTPPropertyValue(raw: data.subdata(in: start..<offset), string: text)
    }
    func finish() throws {
      guard offset == data.count else { throw PTPDatasetError.trailingBytes }
    }
  }
}
