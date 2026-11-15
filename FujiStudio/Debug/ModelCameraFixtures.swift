import FujiCameraCore

#if DEBUG
  import Foundation
  import ImageIO
  import UniformTypeIdentifiers

  func fixtureWirelessOriginals() throws -> (jpeg: Data, raf: Data) {
    func jpeg(width: Int, height: Int) throws -> Data {
      let output = NSMutableData()
      guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
        let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
      else { throw CocoaError(.fileWriteUnknown) }
      let metadata: [String: Any] = [
        kCGImagePropertyOrientation as String: 1,
        kCGImagePropertyTIFFDictionary as String: [
          kCGImagePropertyTIFFMake as String: "FUJIFILM", kCGImagePropertyTIFFModel as String: "X-T5",
        ],
        kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: "2020:01:02 03:04:05"],
      ]
      CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
      return output as Data
    }

    func big32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) } }
    func big16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).bigEndian) { Data($0) } }
    let preview = try jpeg(width: 2, height: 2)
    var raw = Data(repeating: 0, count: 128)
    raw.replaceSubrange(0..<16, with: Data("FUJIFILMCCD-RAW ".utf8))
    raw.replaceSubrange(28..<32, with: Data("X-T5".utf8))
    var tags = big32(4)
    for (tag, first, second) in [(0x100, 5196, 7872), (0x110, 22, 72), (0x111, 5152, 7728), (0x115, 2, 3)] {
      tags += big16(tag) + big16(4) + big16(first) + big16(second)
    }
    for (offset, value) in [(84, 128), (88, preview.count), (92, 128 + preview.count), (96, tags.count),
                            (100, 128 + preview.count + tags.count), (104, 16)] {
      raw.replaceSubrange(offset..<(offset + 4), with: big32(value))
    }
    raw += preview + tags + Data(repeating: 0xab, count: 16)
    return (try jpeg(width: 6, height: 4), raw)
  }

  func fixtureXE3Snapshots() throws -> [RecipeSnapshot] {
    let context = RecipeCameraContext(
      model: "X-E3", firmware: "1.30", capability: XE3Support.identifier, sessionIdentity: UUID(),
      sessionGeneration: 1)
    let fields: [UInt16: Data] = [
      1: Data([13]), 2: Data([3]), 3: Data([1]), 4: Data([8]), 5: Data([13]), 6: Data([11]),
      7: Data([6]), 8: Data([5]), 9: Data([2]), 10: Data([7]), 11: Data([4]), 12: Data([0]),
      13: Data([0xb9, 1]),
    ]
    return try (1...7).map { slot in
      try XE3RecipeCodec.recipe(
        slot: slot, nameData: Data("X-E3 look \(slot)\0".utf8), properties: fields,
        context: context, importedAt: Date(timeIntervalSince1970: 0))
    }
  }
#endif
