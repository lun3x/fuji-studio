import CryptoKit
import Foundation
import ImageIO

/// Parses RAF framing and its small metadata blocks; never asks Core Image to decode RAW pixels.
public struct RAFMetadataReader: Sendable {
  public func prepare(_ resource: LocalResource) throws -> PreparedRAW {
    let checksum = try ResourceChecksum.sha256(resource.fileURL)
    guard checksum == resource.checksum else { throw ResourceError.checksumMismatch }
    let data = try Data(contentsOf: resource.fileURL, options: .mappedIfSafe)
    let metadata = try parse(data, fileByteCount: data.count)
    return PreparedRAW(fileURL: resource.fileURL, sha256: checksum, sourceID: resource.token.assetID,
      sourceRevision: resource.token.sourceRevision, metadata: metadata)
  }

  /// Structural inspection only. nil means another metadata block has not arrived yet.
  /// A known original size validates bounds without reading or hashing the pixel payload.
  public func metadata(in prefix: Data, fileByteCount: Int? = nil) throws -> RAWMetadata? {
    do { return try parse(prefix, fileByteCount: fileByteCount ?? Int.max) }
    catch is IncompleteMetadata { return nil }
  }

  private struct IncompleteMetadata: Error {}

  private func parse(_ data: Data, fileByteCount: Int) throws -> RAWMetadata {
    guard fileByteCount >= 112 else { throw ResourceError.invalidRAF("Truncated RAF header") }
    guard data.count >= 112 else { throw IncompleteMetadata() }
    guard Array(data.prefix(16)) == Array("FUJIFILMCCD-RAW ".utf8) else {
      throw ResourceError.invalidRAF("Missing RAF signature or truncated header")
    }
    let model = String(decoding: data[28..<60].prefix { $0 != 0 }, as: UTF8.self)
      .trimmingCharacters(in: .whitespaces)
    guard !model.isEmpty else { throw ResourceError.invalidRAF("Missing camera model") }
    let payloadOffset = integer(data, 100, 4)
    let payloadLength = integer(data, 104, 4)
    guard payloadOffset >= 112, payloadOffset <= fileByteCount,
      payloadLength > 0, payloadLength <= fileByteCount - payloadOffset
    else {
      throw ResourceError.invalidRAF("Invalid RAW payload bounds")
    }
    let jpeg = try section(data, offsetField: 84, lengthField: 88, fileByteCount: fileByteCount)
    guard
      let source = CGImageSourceCreateWithData(
        jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
      let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
      let exifModel = tiff[kCGImagePropertyTIFFModel as String] as? String,
      exifModel.trimmingCharacters(in: .whitespacesAndNewlines) == model
    else {
      throw ResourceError.invalidRAF("Missing or inconsistent embedded camera metadata")
    }
    let orientation =
      (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
    guard (1...8).contains(orientation) else {
      throw ResourceError.invalidRAF("Invalid orientation")
    }
    let originalRendering = try? FujiJPEGMetadataReader.read(jpeg)
    let captureDynamicRange: Int?
    if case .integer(let value)? = originalRendering?.rendering[.dynamicRange] {
      captureDynamicRange = value
    } else {
      captureDynamicRange = nil
    }
    let directory = try section(data, offsetField: 92, lengthField: 96, fileByteCount: fileByteCount)
    guard directory.count >= 4 else { throw ResourceError.invalidRAF("Truncated RAF directory") }
    let count = integer(directory, 0, 4)
    guard count < 256 else { throw ResourceError.invalidRAF("Invalid RAF directory count") }
    var cursor = 4
    var tags: [Int: [Int]] = [:]
    for _ in 0..<count {
      guard cursor <= directory.count - 4 else {
        throw ResourceError.invalidRAF("Truncated RAF tag")
      }
      let tag = integer(directory, cursor, 2)
      let length = integer(directory, cursor + 2, 2)
      cursor += 4
      guard length <= directory.count - cursor else {
        throw ResourceError.invalidRAF("Truncated RAF tag data")
      }
      if [0x100, 0x110, 0x111, 0x115].contains(tag) {
        guard length == 4, tags[tag] == nil else {
          throw ResourceError.invalidRAF("Invalid geometry tag")
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
      throw ResourceError.invalidRAF("Missing or inconsistent recorded geometry")
    }
    let sensor = try RAFSensorMetadata.read(offset: payloadOffset, length: payloadLength) { range in
      guard range.upperBound <= data.count else { throw IncompleteMetadata() }
      return data.subdata(in: range)
    }
    if let sensor, sensor.width != full[1] || sensor.height != full[0] {
      throw ResourceError.invalidRAF("Inconsistent sensor geometry")
    }
    let compression: RAFCompression? =
      data[108..<111].allSatisfy { $0 == 0 }
      ? RAFCompression(rawValue: UInt32(integer(data, 108, 4))) : nil
    let version = String(data: data.subdata(in: 60..<64), encoding: .ascii).flatMap {
      $0.utf8.allSatisfy { (48...57).contains($0) } ? $0 : nil
    }
    return RAWMetadata(
      cameraModel: model,
      containerGeometry: PixelSize(width: full[1], height: full[0]),
      recordedGeometry: PixelSize(width: crop[1], height: crop[0]),
      recordedAspect: PixelSize(width: aspect[1], height: aspect[0]),
      cropTop: origin[0], cropLeft: origin[1], orientation: orientation, compression: compression,
      bitDepth: sensor?.bits, rafVersion: version, captureDynamicRange: captureDynamicRange,
      captureLensOptimizer: originalRendering?.lensOptimizer,
      lensOptimizerAvailable: originalRendering?.lensOptimizerAvailable)
  }

  private func integer(_ data: Data, _ offset: Int, _ count: Int) -> Int {
    data[offset..<(offset + count)].reduce(0) { ($0 << 8) | Int($1) }
  }

  private func section(_ data: Data, offsetField: Int, lengthField: Int, fileByteCount: Int) throws -> Data {
    let offset = integer(data, offsetField, 4)
    let length = integer(data, lengthField, 4)
    guard offset >= 112, offset <= fileByteCount, length > 0, length <= fileByteCount - offset else {
      throw ResourceError.invalidRAF("Invalid RAF block bounds")
    }
    guard offset + length <= data.count else { throw IncompleteMetadata() }
    return Data(data[offset..<(offset + length)])
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
