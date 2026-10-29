import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Standard ObjectInfo field order used by pinned libfuji's vendor 900C RAF upload. No profile
/// offsets, conversion triggers, response-handle ownership assumptions or deletion logic.
public enum FujiConversionCodec {
  public static func uploadInfo(byteCount: Int) throws -> Data {
    guard byteCount > 0, byteCount <= PTPCodec.maximumDataBytes,
      let count = UInt32(exactly: byteCount)
    else { throw PTPError.payloadTooLarge }
    var bytes = Data(repeating: 0, count: 52)
    bytes[4] = 0x02
    bytes[5] = 0xf8  // Vendor RAF transfer, not backup format 5000.
    for index in 0..<4 { bytes[8 + index] = UInt8(truncatingIfNeeded: count >> (8 * index)) }
    let name = "FUP_FILE.dat"
    bytes.append(UInt8(name.utf16.count + 1))
    for unit in name.utf16 {
      bytes.append(contentsOf: [UInt8(truncatingIfNeeded: unit), UInt8(unit >> 8)])
    }
    bytes.append(contentsOf: [0, 0, 0, 0, 0])  // String terminator and three empty PTP strings.
    return bytes
  }
  public static func objectHandles(_ data: Data) throws -> [UInt32] {
    guard data.count >= 4 else { throw PTPDatasetError.truncated }
    let bytes = Data(data)
    func word(_ offset: Int) -> UInt32 {
      bytes[offset..<(offset + 4)].enumerated().reduce(0) {
        $0 | UInt32($1.element) << ($1.offset * 8)
      }
    }
    let count = Int(word(0))
    guard count <= 4096 else { throw PTPDatasetError.oversized }
    guard data.count >= 4 + count * 4 else { throw PTPDatasetError.truncated }
    guard data.count == 4 + count * 4 else { throw PTPDatasetError.trailingBytes }
    var result: [UInt32] = []
    for offset in stride(from: 4, to: data.count, by: 4) { result.append(word(offset)) }
    guard Set(result).count == result.count, !result.contains(0), !result.contains(UInt32.max)
    else { throw PTPError.invalidParameters }
    return result
  }
}

public struct PTPObjectInfo: Sendable, Equatable, Encodable {
  public let storageID: UInt32, format: UInt16, protection: UInt16, byteCount: UInt32
  public let width: UInt32, height: UInt32, parent: UInt32, associationType: UInt16
  public init(
    storageID: UInt32, format: UInt16, protection: UInt16, byteCount: UInt32, width: UInt32,
    height: UInt32, parent: UInt32, associationType: UInt16
  ) {
    self.storageID = storageID
    self.format = format
    self.protection = protection
    self.byteCount = byteCount
    self.width = width
    self.height = height
    self.parent = parent
    self.associationType = associationType
  }

}
public struct PTPStorageInfo: Sendable, Encodable {
  public let storageType: UInt16, filesystemType: UInt16, access: UInt16
  public let capacity: UInt64, freeBytes: UInt64, freeObjects: UInt32
  public init(
    storageType: UInt16, filesystemType: UInt16, access: UInt16, capacity: UInt64,
    freeBytes: UInt64, freeObjects: UInt32
  ) {
    self.storageType = storageType
    self.filesystemType = filesystemType
    self.access = access
    self.capacity = capacity
    self.freeBytes = freeBytes
    self.freeObjects = freeObjects
  }

}
public struct JPEGObservation: Sendable, Encodable {
  public let width: Int, height: Int, orientation: Int?
  public let modelMatches: Bool, recordedGeometryMatches: Bool, orientationMatches: Bool
  public let fineQualityValidated = false
  public init(
    width: Int, height: Int, orientation: Int? = nil, modelMatches: Bool,
    recordedGeometryMatches: Bool, orientationMatches: Bool
  ) {
    self.width = width
    self.height = height
    self.orientation = orientation
    self.modelMatches = modelMatches
    self.recordedGeometryMatches = recordedGeometryMatches
    self.orientationMatches = orientationMatches
  }

}
public enum XT5ConversionProbeIssue: Error, Sendable {
  case invalidJPEG, unexpectedObjectMetadata, ambiguousOutput, outputTimeout, unexpectedJPEGContext,
    retainedSourceUnavailable
}

extension FujiConversionCodec {
  public static func objectInfo(_ data: Data) throws -> PTPObjectInfo {
    var r = try DatasetReader(data)
    let storage = try r.u32()
    let format = try r.u16()
    let protection = try r.u16()
    let size = try r.u32()
    _ = try r.u16()
    _ = try r.u32()
    _ = try r.u32()
    _ = try r.u32()
    let width = try r.u32()
    let height = try r.u32()
    _ = try r.u32()
    let parent = try r.u32()
    let association = try r.u16()
    _ = try r.u32()
    _ = try r.u32()
    for _ in 0..<4 { try r.skipString() }
    try r.finish()
    return PTPObjectInfo(
      storageID: storage, format: format, protection: protection, byteCount: size, width: width,
      height: height, parent: parent, associationType: association)
  }
  public static func storageInfo(_ data: Data) throws -> PTPStorageInfo {
    var r = try DatasetReader(data)
    let result = try PTPStorageInfo(
      storageType: r.u16(), filesystemType: r.u16(), access: r.u16(), capacity: r.u64(),
      freeBytes: r.u64(), freeObjects: r.u32())
    try r.skipString()
    try r.skipString()
    try r.finish()
    return result
  }
  private struct DatasetReader {
    let data: Data
    var offset = 0
    init(_ data: Data) throws {
      guard data.count <= 4096 else { throw PTPDatasetError.oversized }
      self.data = Data(data)
    }
    mutating func integer(_ width: Int) throws -> UInt64 {
      guard width <= data.count - offset else { throw PTPDatasetError.truncated }
      defer { offset += width }
      return data[offset..<(offset + width)].enumerated().reduce(0) {
        $0 | UInt64($1.element) << ($1.offset * 8)
      }
    }
    mutating func u16() throws -> UInt16 { UInt16(try integer(2)) }
    mutating func u32() throws -> UInt32 { UInt32(try integer(4)) }
    mutating func u64() throws -> UInt64 { try integer(8) }
    mutating func skipString() throws {
      guard offset < data.count else { throw PTPDatasetError.truncated }
      let length = 1 + Int(data[offset]) * 2
      guard length <= data.count - offset else { throw PTPDatasetError.truncated }
      _ = try PTPDatasets.value(data.subdata(in: offset..<(offset + length)), type: 0xffff)
      offset += length
    }
    func finish() throws {
      guard offset == data.count else { throw PTPDatasetError.trailingBytes }
    }
  }
}

extension FujiConversionCodec {
  public static func jpegObservation(_ data: Data, expected: RAWMetadata) throws
    -> JPEGObservation
  {
    guard data.count >= 4, data.count <= PTPCodec.maximumDataBytes,
      data.prefix(2) == Data([0xff, 0xd8]), data.suffix(2) == Data([0xff, 0xd9]),
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetCount(source) == 1,
      CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
      CGImageSourceGetStatus(source) == .statusComplete,
      let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
      let width = (p[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
      let height = (p[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
      width > 0, height > 0, width <= 20_000, height <= 20_000
    else { throw XT5ConversionProbeIssue.invalidJPEG }
    let orientation = (p[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue
    guard orientation == nil || (1...8).contains(orientation!) else {
      throw XT5ConversionProbeIssue.invalidJPEG
    }
    let tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
    let model = (tiff?[kCGImagePropertyTIFFModel as String] as? String)?.trimmingCharacters(
      in: .whitespacesAndNewlines)
    return JPEGObservation(
      width: width, height: height, orientation: orientation,
      modelMatches: model == expected.cameraModel,
      recordedGeometryMatches: width == expected.recordedGeometry.width
        && height == expected.recordedGeometry.height,
      orientationMatches: orientation == expected.orientation)
  }
}

/// Quality and source context validated at runtime. Does not encode ownership or publish a file.
/// Later CameraJPEG construction additionally requires operation provenance and safe cleanup.
public struct ValidatedJPEGMetadata: Sendable, Equatable {
  public let width: Int, height: Int, orientation: Int
  public let make: String, model: String
  public let quality: FujiJPEGQuality
  public let lensOptimizer: Bool?
  public let rendering: [RecipeSettingID: RecipeSettingValue]
  public let unrecognized: Set<RecipeSettingID>
  public init(
    width: Int, height: Int, orientation: Int, make: String, model: String,
    quality: FujiJPEGQuality, lensOptimizer: Bool? = nil,
    rendering: [RecipeSettingID: RecipeSettingValue] = [:], unrecognized: Set<RecipeSettingID> = []
  ) {
    self.width = width
    self.height = height
    self.orientation = orientation
    self.make = make
    self.model = model
    self.quality = quality
    self.lensOptimizer = lensOptimizer
    self.rendering = rendering
    self.unrecognized = unrecognized
  }

}

extension FujiConversionCodec {
  public static func validateFullSizeFineJPEG(_ data: Data, expected: RAWMetadata) throws
    -> ValidatedJPEGMetadata
  {
    let metadata = try FujiJPEGMetadataReader.read(data)
    try metadata.requireFine(
      width: expected.recordedGeometry.width, height: expected.recordedGeometry.height,
      orientation: expected.orientation, model: expected.cameraModel)
    let observed: JPEGObservation
    do { observed = try jpegObservation(data, expected: expected) } catch {
      throw FujiJPEGValidationError.invalidJPEG
    }
    guard observed.modelMatches else { throw FujiJPEGValidationError.cameraMismatch }
    guard observed.recordedGeometryMatches, observed.width == metadata.width,
      observed.height == metadata.height
    else { throw FujiJPEGValidationError.geometryMismatch }
    guard observed.orientationMatches, observed.orientation == metadata.orientation else {
      throw FujiJPEGValidationError.orientationMismatch
    }
    return ValidatedJPEGMetadata(
      width: metadata.width, height: metadata.height, orientation: metadata.orientation,
      make: metadata.make, model: metadata.model, quality: metadata.quality,
      lensOptimizer: metadata.lensOptimizer, rendering: metadata.rendering,
      unrecognized: metadata.unrecognized)
  }
}
