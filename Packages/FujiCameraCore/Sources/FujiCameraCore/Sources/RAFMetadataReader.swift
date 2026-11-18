import CryptoKit
import Foundation
import ImageIO

/// Parses RAF framing and its small metadata blocks; never asks Core Image to decode RAW pixels.
public struct RAFMetadataReader: Sendable {
  public enum Issue: String, Codable, Sendable {
    case invalidFileSize = "Invalid RAF file size"
    case truncatedBlock = "Truncated RAF block"
    case truncatedHeader = "Truncated RAF header"
    case invalidSignature = "Missing RAF signature or truncated header"
    case missingCameraModel = "Missing camera model"
    case invalidPayloadBounds = "Invalid RAW payload bounds"
    case overlappingSections = "Overlapping RAF sections"
    case embeddedJPEGExceedsLimit = "Embedded JPEG metadata exceeds inspection limits"
    case invalidEmbeddedCameraMetadata = "Missing or inconsistent embedded camera metadata"
    case invalidOrientation = "Invalid orientation"
    case truncatedDirectory = "Truncated RAF directory"
    case invalidDirectoryCount = "Invalid RAF directory count"
    case truncatedTagHeader = "Truncated RAF tag"
    case truncatedTagData = "Truncated RAF tag data"
    case invalidGeometryTag = "Invalid geometry tag"
    case invalidRecordedGeometry = "Missing or inconsistent recorded geometry"
    case inconsistentSensorGeometry = "Inconsistent sensor geometry"
    case invalidBlockBounds = "Invalid RAF block bounds"

    fileprivate var error: ResourceError { .invalidRAF(rawValue) }
  }

  public func prepare(_ resource: LocalResource) throws -> PreparedRAW {
    let checksum = try ResourceChecksum.sha256(resource.fileURL)
    guard checksum == resource.checksum else { throw ResourceError.checksumMismatch }
    let data = try Data(contentsOf: resource.fileURL, options: .mappedIfSafe)
    let metadata = try parse(prefix: data, fileByteCount: data.count).metadata
    return PreparedRAW(fileURL: resource.fileURL, sha256: checksum, sourceID: resource.token.assetID,
      sourceRevision: resource.token.sourceRevision, metadata: metadata)
  }

  /// Structural inspection only. nil means another metadata block has not arrived yet.
  /// A known original size validates bounds without reading or hashing the pixel payload.
  public func metadata(in prefix: Data, fileByteCount: Int? = nil) throws -> RAWMetadata? {
    do { return try parse(prefix: prefix, fileByteCount: fileByteCount ?? Int.max).metadata }
    catch is IncompleteMetadata { return nil }
  }

  /// Extracts the Exif IFD1 JPEG when its entire range is in the received RAF prefix.
  func embeddedThumbnail(in prefix: Data, fileByteCount: Int) -> Data? {
    let bytes = Data(prefix)
    guard bytes.count >= 112, bytes.starts(with: "FUJIFILMCCD-RAW ".utf8),
      let section = try? section(bytes, offsetField: 84, lengthField: 88, fileByteCount: fileByteCount),
      section.lowerBound + 2 <= bytes.count,
      integer(bytes, section.lowerBound, 2) == 0xffd8
    else { return nil }
    let end = min(section.upperBound, bytes.count)
    var marker = section.lowerBound + 2
    while marker + 4 <= end {
      guard bytes[marker] == 0xff, bytes[marker + 1] != 0xda else { return nil }
      let length = integer(bytes, marker + 2, 2)
      guard length >= 2 else { return nil }
      let next = marker + 2 + length
      let available = min(next, end)
      if bytes[marker + 1] == 0xe1, marker + 10 <= available,
         bytes[(marker + 4)..<(marker + 10)].elementsEqual([69, 120, 105, 102, 0, 0]) {
        return exifThumbnail(bytes.subdata(in: (marker + 10)..<available))
      }
      marker = next
    }
    return nil
  }

  private func exifThumbnail(_ bytes: Data) -> Data? {
    guard bytes.count >= 8 else { return nil }
    let little: Bool
    switch (bytes[0], bytes[1]) {
    case (0x49, 0x49): little = true
    case (0x4d, 0x4d): little = false
    default: return nil
    }
    func number(_ offset: Int, _ count: Int) -> Int? {
      guard offset >= 0, offset <= bytes.count - count else { return nil }
      let order = little ? Array((0..<count).reversed()) : Array(0..<count)
      return order.reduce(0) { ($0 << 8) | Int(bytes[offset + $1]) }
    }
    guard number(2, 2) == 42, let ifd0 = number(4, 4),
      let entries0 = number(ifd0, 2), let ifd1 = number(ifd0 + 2 + 12 * entries0, 4),
      ifd1 > 0, let entries = number(ifd1, 2), ifd1 + 2 + 12 * entries <= bytes.count
    else { return nil }
    var offset: Int?
    var length: Int?
    for index in 0..<entries {
      let entry = ifd1 + 2 + 12 * index
      guard number(entry + 2, 2) == 4, number(entry + 4, 4) == 1 else { continue }
      switch number(entry, 2) {
      case 0x0201: offset = number(entry + 8, 4)
      case 0x0202: length = number(entry + 8, 4)
      default: break
      }
    }
    guard let offset, let length, offset > 0, length >= 4,
      offset <= bytes.count, length <= bytes.count - offset,
      integer(bytes, offset, 2) == 0xffd8,
      integer(bytes, offset + length - 2, 2) == 0xffd9
    else { return nil }
    return bytes.subdata(in: offset..<(offset + length))
  }

  /// Reads only bounded RAF header blocks, including the embedded JPEG metadata, using seeks.
  /// A corrupt framing offset cannot make this read the full RAW pixel payload.
  public func metadata(inFileAt url: URL) throws -> (metadata: RAWMetadata, embeddedJPEGProperties: [String: Any]) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    guard let size = Int(exactly: try handle.seekToEnd()) else {
      throw Issue.invalidFileSize.error
    }
    return try parse(fileByteCount: size, maximumJPEGBytes: 32 * 1024 * 1024) { range in
      try handle.seek(toOffset: UInt64(range.lowerBound))
      guard let bytes = try handle.read(upToCount: range.count), bytes.count == range.count else {
        throw Issue.truncatedBlock.error
      }
      return bytes
    }
  }

  private struct IncompleteMetadata: Error {}

  private func parse(prefix: Data, fileByteCount: Int) throws -> (metadata: RAWMetadata, embeddedJPEGProperties: [String: Any]) {
    try parse(fileByteCount: fileByteCount, maximumJPEGBytes: Int.max) { range in
      guard range.upperBound <= prefix.count else { throw IncompleteMetadata() }
      return prefix.subdata(in: range)
    }
  }

  private func parse(fileByteCount: Int, maximumJPEGBytes: Int, read: (Range<Int>) throws -> Data) throws
    -> (metadata: RAWMetadata, embeddedJPEGProperties: [String: Any])
  {
    guard fileByteCount >= 112 else { throw Issue.truncatedHeader.error }
    let data = try read(0..<112)
    guard Array(data.prefix(16)) == Array("FUJIFILMCCD-RAW ".utf8) else {
      throw Issue.invalidSignature.error
    }
    let model = String(decoding: data[28..<60].prefix { $0 != 0 }, as: UTF8.self)
      .trimmingCharacters(in: .whitespaces)
    guard !model.isEmpty else { throw Issue.missingCameraModel.error }
    let payloadOffset = integer(data, 100, 4)
    let payloadLength = integer(data, 104, 4)
    guard payloadOffset >= 112, payloadOffset <= fileByteCount,
      payloadLength > 0, payloadLength <= fileByteCount - payloadOffset
    else {
      throw Issue.invalidPayloadBounds.error
    }
    let jpegRange = try section(data, offsetField: 84, lengthField: 88, fileByteCount: fileByteCount)
    let directoryRange = try section(data, offsetField: 92, lengthField: 96, fileByteCount: fileByteCount)
    let payloadRange = payloadOffset..<(payloadOffset + payloadLength)
    guard !jpegRange.overlaps(directoryRange), !jpegRange.overlaps(payloadRange),
      !directoryRange.overlaps(payloadRange)
    else {
      throw Issue.overlappingSections.error
    }
    guard jpegRange.count <= maximumJPEGBytes else {
      throw Issue.embeddedJPEGExceedsLimit.error
    }
    let jpeg = try read(jpegRange)
    guard
      let source = CGImageSourceCreateWithData(
        jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
      let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
      let exifModel = tiff[kCGImagePropertyTIFFModel as String] as? String,
      exifModel.trimmingCharacters(in: .whitespacesAndNewlines) == model
    else {
      throw Issue.invalidEmbeddedCameraMetadata.error
    }
    let orientation =
      (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
    guard (1...8).contains(orientation) else {
      throw Issue.invalidOrientation.error
    }
    let captureDynamicRange: Int?
    if case .integer(let value)? = (try? FujiJPEGMetadataReader.read(jpeg))?.rendering[.dynamicRange] {
      captureDynamicRange = value
    } else {
      captureDynamicRange = nil
    }
    // At most 255 tags, each with a 16-bit length and a four-byte header.
    let directory = try read(directoryRange.prefix(4 + 255 * (Int(UInt16.max) + 4)))
    guard directory.count >= 4 else { throw Issue.truncatedDirectory.error }
    let count = integer(directory, 0, 4)
    guard count < 256 else { throw Issue.invalidDirectoryCount.error }
    var cursor = 4
    var tags: [Int: [Int]] = [:]
    for _ in 0..<count {
      guard cursor <= directory.count - 4 else {
        throw Issue.truncatedTagHeader.error
      }
      let tag = integer(directory, cursor, 2)
      let length = integer(directory, cursor + 2, 2)
      cursor += 4
      guard length <= directory.count - cursor else {
        throw Issue.truncatedTagData.error
      }
      if [0x100, 0x110, 0x111, 0x115].contains(tag) {
        guard length == 4, tags[tag] == nil else {
          throw Issue.invalidGeometryTag.error
        }
        tags[tag] = [integer(directory, cursor, 2), integer(directory, cursor + 2, 2)]
      }
      cursor += length
    }
    guard let full = tags[0x100], let crop = tags[0x111], let origin = tags[0x110],
      let aspect = tags[0x115],
      full.allSatisfy({ $0 > 0 }), crop.allSatisfy({ $0 > 0 }), aspect.allSatisfy({ $0 > 0 }),
      origin[0] + crop[0] <= full[0], origin[1] + crop[1] <= full[1]
    else {
      throw Issue.invalidRecordedGeometry.error
    }
    let sensor = try RAFSensorMetadata.read(offset: payloadOffset, length: payloadLength, bytes: read)
    if let sensor, sensor.width != full[1] || sensor.height != full[0] {
      throw Issue.inconsistentSensorGeometry.error
    }
    let compression: RAFCompression? =
      data[108..<111].allSatisfy { $0 == 0 }
      ? RAFCompression(rawValue: UInt32(integer(data, 108, 4))) : nil
    let version = String(data: data.subdata(in: 60..<64), encoding: .ascii).flatMap {
      $0.utf8.allSatisfy { (48...57).contains($0) } ? $0 : nil
    }
    let metadata = RAWMetadata(
      cameraModel: model,
      containerGeometry: PixelSize(width: full[1], height: full[0]),
      recordedGeometry: PixelSize(width: crop[1], height: crop[0]),
      recordedAspect: PixelSize(width: aspect[1], height: aspect[0]),
      cropTop: origin[0], cropLeft: origin[1], orientation: orientation, compression: compression,
      bitDepth: sensor?.bits, rafVersion: version, captureDynamicRange: captureDynamicRange)
    return (metadata, properties)
  }

  private func integer(_ data: Data, _ offset: Int, _ count: Int) -> Int {
    data[offset..<(offset + count)].reduce(0) { ($0 << 8) | Int($1) }
  }

  private func section(_ data: Data, offsetField: Int, lengthField: Int, fileByteCount: Int) throws -> Range<Int> {
    let offset = integer(data, offsetField, 4)
    let length = integer(data, lengthField, 4)
    guard offset >= 112, offset <= fileByteCount, length > 0, length <= fileByteCount - offset else {
      throw Issue.invalidBlockBounds.error
    }
    return offset..<(offset + length)
  }
  public init() {}

}

public enum ResourceChecksum {
  public static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  public static func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
      try Task.checkCancellation()
      hash.update(data: data)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
