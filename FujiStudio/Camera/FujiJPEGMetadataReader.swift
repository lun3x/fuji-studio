import Foundation

/// Original bounded reader; ExifTool 13.55 FujiFilm/MakerNotes are format references only.
/// Parses headers/metadata, not entropy coefficients. Production validation additionally uses ImageIO.
enum FujiJPEGQuality: String, Sendable, Equatable {
  case fine = "FINE"
  case normal = "NORMAL"
}
enum FujiJPEGValidationError: Error, Sendable, Equatable {
  case invalidJPEG, resourceLimit, invalidTIFF, duplicateMetadata, conflictingMetadata
  case missingMetadata, unsupportedMakerNote, unsupportedQuality, notFine
  case cameraMismatch, geometryMismatch, orientationMismatch
}
struct FujiJPEGMetadata: Sendable, Equatable {
  let width: Int, height: Int, orientation: Int
  let make: String, model: String
  let quality: FujiJPEGQuality
  let lensOptimizer: Bool?
  func requireFine(width: Int, height: Int, orientation: Int, model: String) throws {
    guard model == "X-T5", self.model == model, make == "FUJIFILM" else {
      throw FujiJPEGValidationError.cameraMismatch
    }
    guard self.width == width, self.height == height else {
      throw FujiJPEGValidationError.geometryMismatch
    }
    guard self.orientation == orientation else { throw FujiJPEGValidationError.orientationMismatch }
    guard quality == .fine else { throw FujiJPEGValidationError.notFine }
  }
}

enum FujiJPEGMetadataReader {
  static let maximumJPEGBytes = 128 * 1024 * 1024
  private static let maximumMarkers = 16_384
  static func read(_ data: Data) throws -> FujiJPEGMetadata {
    guard data.count <= maximumJPEGBytes else { throw FujiJPEGValidationError.resourceLimit }
    return try data.withUnsafeBytes { bytes in
      let all = Region(bytes: bytes, base: 0, count: bytes.count)
      guard try all.u16(0, little: false) == 0xffd8 else {
        throw FujiJPEGValidationError.invalidJPEG
      }
      var offset = 2
      var markers = 0
      var inScan = false
      var scanBytes = 0
      var scans = 0
      var exif: Region?
      var dimensions: (Int, Int)?
      var components: Set<UInt8> = []
      while offset < all.count {
        if inScan && all.byte(offset) != 0xff {
          offset += 1
          scanBytes += 1
          continue
        }
        guard all.byte(offset) == 0xff else { throw FujiJPEGValidationError.invalidJPEG }
        repeat { offset += 1 } while offset < all.count && all.byte(offset) == 0xff
        try all.check(offset, 1)
        let marker = all.byte(offset)
        offset += 1
        if inScan && marker == 0 {
          scanBytes += 1
          continue
        }
        // Restart markers belong to bounded entropy data, not the header/IFD budget.
        // Full-size camera JPEGs contain more than 77,000 of them.
        if inScan && (0xd0...0xd7).contains(marker) { continue }
        markers += 1
        guard markers <= maximumMarkers else { throw FujiJPEGValidationError.resourceLimit }
        inScan = false
        if marker == 0xd9 {
          guard offset == all.count, scans > 0, scanBytes > 0, let exif, let dimensions else {
            throw FujiJPEGValidationError.invalidJPEG
          }
          var parser = TIFFParser(region: exif)
          return try parser.read(width: dimensions.0, height: dimensions.1)
        }
        guard marker != 0 && marker != 0xd8 && marker != 1 && !(0xd0...0xd7).contains(marker) else {
          throw FujiJPEGValidationError.invalidJPEG
        }
        let length = try all.u16(offset, little: false)
        guard length >= 2 else { throw FujiJPEGValidationError.invalidJPEG }
        try all.check(offset, length)
        let body = try all.slice(offset + 2, length - 2)
        if marker == 0xe1 && body.starts([0x45, 0x78, 0x69, 0x66]) {
          guard body.starts([0x45, 0x78, 0x69, 0x66, 0, 0]) else {
            throw FujiJPEGValidationError.invalidTIFF
          }
          guard exif == nil else { throw FujiJPEGValidationError.duplicateMetadata }
          exif = try body.slice(6, body.count - 6)
        }
        if [UInt8(0xc0), 0xc1, 0xc2].contains(marker) {
          guard dimensions == nil, body.count >= 6, body.byte(0) == 8 else {
            throw FujiJPEGValidationError.invalidJPEG
          }
          let height = try body.u16(1, little: false)
          let width = try body.u16(3, little: false)
          let count = Int(body.byte(5))
          guard width > 0, height > 0, width <= 20_000, height <= 20_000, [1, 3].contains(count),
            body.count == 6 + 3 * count
          else { throw FujiJPEGValidationError.invalidJPEG }
          for i in 0..<count {
            guard components.insert(body.byte(6 + 3 * i)).inserted else {
              throw FujiJPEGValidationError.invalidJPEG
            }
          }
          dimensions = (width, height)
        } else if (0xc0...0xcf).contains(marker) && ![UInt8(0xc4), 0xc8, 0xcc].contains(marker) {
          throw FujiJPEGValidationError.invalidJPEG  // No unsupported SOF/alternate image fallback.
        }
        if marker == 0xda {
          guard dimensions != nil, body.count >= 4 else {
            throw FujiJPEGValidationError.invalidJPEG
          }
          let count = Int(body.byte(0))
          guard count > 0, count <= components.count, body.count == 4 + 2 * count else {
            throw FujiJPEGValidationError.invalidJPEG
          }
          var selected: Set<UInt8> = []
          for i in 0..<count {
            let component = body.byte(1 + 2 * i)
            guard components.contains(component), selected.insert(component).inserted else {
              throw FujiJPEGValidationError.invalidJPEG
            }
          }
          scans += 1
          inScan = true
        }
        offset += length
      }
      throw FujiJPEGValidationError.invalidJPEG
    }
  }

  /// Offsets are relative to an already bounded region; no input-sized copies/allocations.
  private struct Region {
    let bytes: UnsafeRawBufferPointer
    let base: Int, count: Int
    func check(_ offset: Int, _ length: Int) throws {
      guard offset >= 0, length >= 0, offset <= count, length <= count - offset else {
        throw FujiJPEGValidationError.invalidTIFF
      }
    }
    func byte(_ offset: Int) -> UInt8 { bytes[base + offset] }  // Only called after local bounds checks.
    func u16(_ offset: Int, little: Bool) throws -> Int {
      try check(offset, 2)
      return little
        ? Int(byte(offset)) | Int(byte(offset + 1)) << 8
        : Int(byte(offset)) << 8 | Int(byte(offset + 1))
    }
    func u32(_ offset: Int, little: Bool) throws -> Int {
      try check(offset, 4)
      var value: UInt32 = 0
      for i in 0..<4 { value |= UInt32(byte(offset + i)) << ((little ? i : 3 - i) * 8) }
      return Int(value)
    }
    func slice(_ offset: Int, _ length: Int) throws -> Region {
      try check(offset, length)
      return Region(bytes: bytes, base: base + offset, count: length)
    }
    func starts(_ prefix: [UInt8]) -> Bool {
      count >= prefix.count && prefix.enumerated().allSatisfy { byte($0.offset) == $0.element }
    }
    func ascii(_ offset: Int, _ length: Int, maximum: Int) throws -> String {
      guard length >= 2, length <= maximum else { throw FujiJPEGValidationError.invalidTIFF }
      try check(offset, length)
      var content: [UInt8] = []
      var terminated = false
      for i in 0..<length {
        let b = byte(offset + i)
        if b == 0 {
          terminated = true
        } else {
          guard !terminated, (32...126).contains(b) else {
            throw FujiJPEGValidationError.invalidTIFF
          }
          content.append(b)
        }
      }
      guard terminated else { throw FujiJPEGValidationError.invalidTIFF }
      while content.last == 32 { content.removeLast() }
      guard !content.isEmpty, let value = String(bytes: content, encoding: .ascii) else {
        throw FujiJPEGValidationError.invalidTIFF
      }
      return value
    }
  }
  private struct Entry { let tag: Int, type: Int, count: Int, value: Int, length: Int }
  private struct Directory { let entries: [Entry], next: Int }
  private struct IFDReader {
    let region: Region, little: Bool, headerBytes: Int
    var structures: [Range<Int>] = []
    var outOfLine: [Range<Int>] = []
    var visited: Set<Int> = []
    var totalEntries = 0
    mutating func directory(_ offset: Int) throws -> Directory {
      guard offset >= headerBytes, offset % 2 == 0, visited.insert(offset).inserted else {
        throw FujiJPEGValidationError.invalidTIFF
      }
      guard visited.count <= 16 else { throw FujiJPEGValidationError.resourceLimit }
      let n = try region.u16(offset, little: little)
      guard n <= 512, totalEntries + n <= 2048 else { throw FujiJPEGValidationError.resourceLimit }
      totalEntries += n
      let size = 2 + 12 * n + 4
      try region.check(offset, size)
      let structure = offset..<offset + size
      guard !structures.contains(where: { $0.overlaps(structure) }) else {
        throw FujiJPEGValidationError.invalidTIFF
      }
      structures.append(structure)
      var entries: [Entry] = []
      var tags: Set<Int> = []
      let widths = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8]
      for i in 0..<n {
        let at = offset + 2 + i * 12
        let tag = try region.u16(at, little: little)
        let type = try region.u16(at + 2, little: little)
        let count = try region.u32(at + 4, little: little)
        guard tags.insert(tag).inserted else { throw FujiJPEGValidationError.duplicateMetadata }
        guard (1..<widths.count).contains(type), count > 0, count <= region.count / widths[type]
        else { throw FujiJPEGValidationError.invalidTIFF }
        let length = count * widths[type]
        let value = length <= 4 ? at + 8 : try region.u32(at + 8, little: little)
        try region.check(value, length)
        if length > 4 {
          guard value >= headerBytes else { throw FujiJPEGValidationError.invalidTIFF }
          outOfLine.append(value..<value + length)
        }
        entries.append(Entry(tag: tag, type: type, count: count, value: value, length: length))
      }
      return Directory(entries: entries, next: try region.u32(offset + 2 + n * 12, little: little))
    }
    func validateValueRanges() throws {
      guard !outOfLine.contains(where: { value in structures.contains { $0.overlaps(value) } })
      else { throw FujiJPEGValidationError.invalidTIFF }
    }
    func scalar(_ e: Entry) throws -> Int {
      guard e.count == 1, [3, 4].contains(e.type) else { throw FujiJPEGValidationError.invalidTIFF }
      return e.type == 3
        ? try region.u16(e.value, little: little) : try region.u32(e.value, little: little)
    }
    func pointer(_ e: Entry) throws -> Int {
      guard e.type == 4 else { throw FujiJPEGValidationError.invalidTIFF }
      return try scalar(e)
    }
  }
  private struct TIFFParser {
    enum Kind { case primary, exif, gps, interoperability, thumbnail }
    let region: Region
    var reader: IFDReader?
    var make: String?, model: String?, orientation: Int?, thumbnailOrientation: Int?,
      quality: FujiJPEGQuality?
    var lensOptimizer: Bool?
    var thumbnailMake: String?, thumbnailModel: String?, pixelWidth: Int?, pixelHeight: Int?,
      thumbnailOffset: Int?, thumbnailLength: Int?
    mutating func read(width: Int, height: Int) throws -> FujiJPEGMetadata {
      let little: Bool
      if region.starts([0x49, 0x49]) {
        little = true
      } else if region.starts([0x4d, 0x4d]) {
        little = false
      } else {
        throw FujiJPEGValidationError.invalidTIFF
      }
      guard try region.u16(2, little: little) == 42 else {
        throw FujiJPEGValidationError.invalidTIFF
      }
      reader = IFDReader(region: region, little: little, headerBytes: 8)
      try visit(region.u32(4, little: little), kind: .primary, depth: 0)
      try reader!.validateValueRanges()
      guard let make, let model, let orientation, let quality else {
        throw FujiJPEGValidationError.missingMetadata
      }
      guard thumbnailOrientation == nil || thumbnailOrientation == orientation,
        thumbnailMake == nil || thumbnailMake == make,
        thumbnailModel == nil || thumbnailModel == model,
        pixelWidth == nil || pixelWidth == width, pixelHeight == nil || pixelHeight == height
      else { throw FujiJPEGValidationError.conflictingMetadata }
      if thumbnailOffset != nil || thumbnailLength != nil {
        guard let thumbnailOffset, let thumbnailLength, thumbnailLength > 0 else {
          throw FujiJPEGValidationError.invalidTIFF
        }
        try region.check(thumbnailOffset, thumbnailLength)
      }
      return FujiJPEGMetadata(
        width: width, height: height, orientation: orientation, make: make, model: model,
        quality: quality, lensOptimizer: lensOptimizer)
    }
    mutating func visit(_ offset: Int, kind: Kind, depth: Int) throws {
      guard depth <= 4 else { throw FujiJPEGValidationError.resourceLimit }
      let dir = try reader!.directory(offset)
      for e in dir.entries {
        switch e.tag {
        case 0x10f, 0x110:
          guard kind == .primary || kind == .thumbnail, e.type == 2 else {
            throw FujiJPEGValidationError.conflictingMetadata
          }
          let value = try region.ascii(e.value, e.length, maximum: 64)
          if kind == .primary {
            if e.tag == 0x10f { make = value } else { model = value }
          } else {
            if e.tag == 0x10f { thumbnailMake = value } else { thumbnailModel = value }
          }
        case 0x112:
          guard kind == .primary || kind == .thumbnail, e.type == 3 else {
            throw FujiJPEGValidationError.conflictingMetadata
          }
          let value = try reader!.scalar(e)
          guard (1...8).contains(value) else { throw FujiJPEGValidationError.invalidTIFF }
          if kind == .primary { orientation = value } else { thumbnailOrientation = value }
        case 0x8769, 0x8825:
          guard kind == .primary else { throw FujiJPEGValidationError.duplicateMetadata }
          try visit(reader!.pointer(e), kind: e.tag == 0x8769 ? .exif : .gps, depth: depth + 1)
        case 0xa005:
          guard kind == .exif else { throw FujiJPEGValidationError.invalidTIFF }
          try visit(reader!.pointer(e), kind: .interoperability, depth: depth + 1)
        case 0x927c:
          guard kind == .exif, e.type == 7, quality == nil else {
            throw FujiJPEGValidationError.duplicateMetadata
          }
          let maker = try makerQuality(region.slice(e.value, e.length))
          quality = maker.quality
          lensOptimizer = maker.lensOptimizer
        case 0xa002, 0xa003:
          guard kind == .exif else { throw FujiJPEGValidationError.conflictingMetadata }
          let value = try reader!.scalar(e)
          if e.tag == 0xa002 { pixelWidth = value } else { pixelHeight = value }
        case 0x201, 0x202:
          guard kind == .thumbnail else { throw FujiJPEGValidationError.conflictingMetadata }
          let value = try reader!.pointer(e)
          if e.tag == 0x201 { thumbnailOffset = value } else { thumbnailLength = value }
        case 0x14a: throw FujiJPEGValidationError.invalidTIFF  // Unsupported SubIFD graph, never silently selected.
        default: break  // Valid bounded unrelated metadata is not interpreted or exposed.
        }
      }
      if dir.next != 0 {
        guard kind == .primary else { throw FujiJPEGValidationError.invalidTIFF }
        try visit(dir.next, kind: .thumbnail, depth: depth + 1)
      }
    }
    private func makerQuality(_ note: Region) throws -> (quality: FujiJPEGQuality, lensOptimizer: Bool?) {
      guard note.starts(Array("FUJIFILM".utf8)) else {
        throw FujiJPEGValidationError.unsupportedMakerNote
      }
      var maker = IFDReader(region: note, little: true, headerBytes: 12)
      let dir = try maker.directory(note.u32(8, little: true))
      guard dir.next == 0 else { throw FujiJPEGValidationError.invalidTIFF }
      try maker.validateValueRanges()
      guard let entry = dir.entries.first(where: { $0.tag == 0x1000 }) else {
        throw FujiJPEGValidationError.missingMetadata
      }
      guard entry.type == 2 else { throw FujiJPEGValidationError.invalidTIFF }
      let text = try note.ascii(entry.value, entry.length, maximum: 32)
      guard let quality = FujiJPEGQuality(rawValue: text) else {
        throw FujiJPEGValidationError.unsupportedQuality
      }
      var lensOptimizer: Bool?
      if let entry = dir.entries.first(where: { $0.tag == 0x1045 }) {
        guard entry.type == 4, entry.count == 1 else { throw FujiJPEGValidationError.invalidTIFF }
        let value = try note.u32(entry.value, little: true)
        guard value == 0 || value == 1 else { throw FujiJPEGValidationError.conflictingMetadata }
        lensOptimizer = value == 1
      }
      return (quality, lensOptimizer)

    }
  }
}
