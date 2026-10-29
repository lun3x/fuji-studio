import Foundation

/// Bounded TIFF scalar inspection, independent of RAW pixel decoding.
/// The measured RAF 0130 layout stores a type-13 Fuji SubIFD at tag F000.
enum RAFSensorMetadata {
  struct Values {
    let width: Int
    let height: Int
    let bits: Int
  }
  static func read(offset: Int, length: Int, bytes: (Range<Int>) throws -> Data) throws -> Values? {
    guard length >= 8, offset >= 0,
      try bytes(offset..<offset + 4) == Data([0x49, 0x49, 42, 0])
    else { return nil }
    func integer(_ at: Int, _ count: Int) throws -> Int? {
      guard at >= 0, count <= length, at <= length - count else { return nil }
      let data = try bytes(offset + at..<offset + at + count)
      return (0..<count).reduce(0) { $0 | Int(data[$1]) << ($1 * 8) }
    }
    func directory(_ at: Int) throws -> [Int: (type: Int, count: Int, value: Int)]? {
      guard let count = try integer(at, 2), (1...256).contains(count), at <= length - 6 - count * 12
      else { return nil }
      var tags: [Int: (Int, Int, Int)] = [:]
      for index in 0..<count {
        let entry = at + 2 + 12 * index
        guard let tag = try integer(entry, 2), let type = try integer(entry + 2, 2),
          let count = try integer(entry + 4, 4), let value = try integer(entry + 8, 4), tags[tag] == nil
        else { return nil }
        tags[tag] = (type, count, value)
      }
      return tags
    }
    guard let first = try integer(4, 4), let root = try directory(first), let child = root[0xf000],
      child.type == 13, child.count == 1, child.value != first, let sensor = try directory(child.value)
    else { return nil }
    func scalar(_ tag: Int) -> Int? {
      guard let field = sensor[tag], field.type == 4, field.count == 1 else { return nil }
      return field.value
    }
    guard let width = scalar(0xf001), let height = scalar(0xf002), let bits = scalar(0xf003) else {
      return nil
    }
    return Values(width: width, height: height, bits: bits)
  }
}
