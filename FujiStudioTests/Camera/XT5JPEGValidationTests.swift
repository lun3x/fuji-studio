import Foundation
import Testing

@testable import FujiStudio

struct XT5JPEGValidationTests {
  @Test func readsFineAndNormalWithBothTIFFByteOrdersAndMatchingThumbnail() throws {
    for little in [true, false] {
      for quality in ["FINE   ", "NORMAL "] {
        let f = JPEGQualityFixture(quality: quality, little: little, thumbnailOrientation: 8)
        let value = try FujiJPEGMetadataReader.read(f.jpeg)
        #expect(value.quality == (quality.hasPrefix("FINE") ? .fine : .normal))
        #expect(value.make == "FUJIFILM" && value.model == "X-T5")
        #expect(value.width == 4 && value.height == 6 && value.orientation == 8)
      }
    }
  }
  @Test func boundsStructuralMarkersSeparatelyFromEntropyRestartMarkers() throws {
    let f = JPEGQualityFixture()
    var withRestarts = Data(f.jpeg.dropLast(2))
    for i in 0..<80_000 { withRestarts.append(contentsOf: [0xff, UInt8(0xd0 + i % 8), 0x11]) }
    withRestarts.append(contentsOf: [0xff, 0xd9])
    #expect(try FujiJPEGMetadataReader.read(withRestarts).quality == .fine)
    var excessiveHeaders = Data([0xff, 0xd8])
    for _ in 0..<16_385 { excessiveHeaders.append(contentsOf: [0xff, 0xfe, 0, 2]) }
    excessiveHeaders.append(f.jpeg.dropFirst(2))
    #expect(throws: FujiJPEGValidationError.resourceLimit) {
      try FujiJPEGMetadataReader.read(excessiveHeaders)
    }
  }
  @Test func rejectsAmbiguousCarriersTagsAndThumbnailConflict() throws {
    let cases = [
      JPEGQualityFixture(duplicateQuality: true), JPEGQualityFixture(duplicateMaker: true),
      JPEGQualityFixture(duplicateOrientation: true), JPEGQualityFixture(thumbnailOrientation: 1),
    ]
    for f in cases {
      #expect(throws: FujiJPEGValidationError.self) { try FujiJPEGMetadataReader.read(f.jpeg) }
    }
    let f = JPEGQualityFixture()
    let doubled = Data([0xff, 0xd8]) + f.exifSegment + f.exifSegment + f.imageBody
    #expect(throws: FujiJPEGValidationError.self) { try FujiJPEGMetadataReader.read(doubled) }
  }
  @Test func rejectsMissingUnsupportedAndMalformedQuality() throws {
    for quality in ["BASIC", "SUPERFINE", "fine", " FINE", "FINE\n"] {
      #expect(throws: FujiJPEGValidationError.self) {
        try FujiJPEGMetadataReader.read(JPEGQualityFixture(quality: quality).jpeg)
      }
    }
    let f = JPEGQualityFixture()
    #expect(throws: FujiJPEGValidationError.self) {
      try FujiJPEGMetadataReader.read(Data([0xff, 0xd8]) + f.imageBody)
    }
    for mutation in [
      f.changed(f.qualityEntry, bytes: [1, 0x10]), f.changed(f.qualityEntry + 2, bytes: [7, 0]),
      f.changed(f.qualityEntry + 4, bytes: [0, 0, 0, 0]),
      f.changed(f.qualityValue + 7, bytes: [0x41]),
    ] {
      #expect(throws: FujiJPEGValidationError.self) { try FujiJPEGMetadataReader.read(mutation) }
    }
  }
  @Test func refusesTruncationOverflowOffsetsCyclesAndImpossibleEndianStructures() throws {
    let f = JPEGQualityFixture()
    let mutations = [
      f.changed(f.tiff, bytes: [0x5a, 0x5a]), f.changed(f.tiff + 2, bytes: [43, 0]),
      f.changed(f.tiff + 4, bytes: [0xff, 0xff, 0xff, 0xff]),
      f.changed(f.tiff + 8, bytes: [0xff, 0xff]),
      f.changed(f.exifPointer, bytes: [8, 0, 0, 0]),
      f.changed(f.makerEntry + 4, bytes: [0xff, 0xff, 0xff, 0xff]),
      f.changed(f.maker, bytes: [0x58]), f.changed(f.qualityEntry + 2, bytes: [13, 0]),
      f.changed(f.makerEntry + 20, bytes: [5, 0, 0, 0]),
      f.changed(f.maker + 8, bytes: [0, 0, 0, 12]),
      f.changed(f.maker + 8, bytes: [0xff, 0xff, 0xff, 0xff]),
      f.changed(f.qualityEntry + 4, bytes: [0xff, 0xff, 0xff, 0xff]),
      f.changed(f.qualityEntry + 8, bytes: [0xff, 0xff, 0xff, 0xff]),
      f.changed(f.qualityEntry + 8, bytes: [12, 0, 0, 0]), f.changed(4, bytes: [0xff, 0xff]),
    ]
    for mutation in mutations {
      #expect(throws: FujiJPEGValidationError.self) { try FujiJPEGMetadataReader.read(mutation) }
    }
    for length in [0, 1, 2, 5, f.tiff + 7, f.maker + 11, f.jpeg.count - 1] {
      #expect(throws: FujiJPEGValidationError.self) {
        try FujiJPEGMetadataReader.read(Data(f.jpeg.prefix(length)))
      }
    }
  }
  @Test func productionValidationRequiresFineAndExactRecordedContextWithoutChangingBytes() throws {
    let image = try ObjectObservationFixture.jpeg()
    let data = JPEGQualityFixture().inject(into: image)
    let before = data
    let metadata = try XT5ConversionCodec.validateFullSizeFineJPEG(
      data, expected: ObjectObservationFixture.metadata)
    #expect(metadata.width == 4 && metadata.height == 6 && metadata.orientation == 8)
    #expect(metadata.quality == .fine && metadata.make == "FUJIFILM" && metadata.model == "X-T5")
    #expect(data == before)
    #expect(
      try XT5ConversionCodec.jpegObservation(data, expected: ObjectObservationFixture.metadata)
        .fineQualityValidated == false)
    for f in [
      JPEGQualityFixture(quality: "NORMAL "), JPEGQualityFixture(make: "OTHER"),
      JPEGQualityFixture(model: "X-T4"), JPEGQualityFixture(orientation: 1),
    ] {
      #expect(throws: FujiJPEGValidationError.self) {
        try XT5ConversionCodec.validateFullSizeFineJPEG(
          f.inject(into: image), expected: ObjectObservationFixture.metadata)
      }
    }
    #expect(throws: FujiJPEGValidationError.notFine) {
      try XT5ConversionCodec.validateFullSizeFineJPEG(
        JPEGQualityFixture(quality: "NORMAL ").inject(into: image),
        expected: ObjectObservationFixture.metadata)
    }
    let wrong = RAWMetadata(
      cameraModel: "X-T5", containerGeometry: .init(width: 5, height: 6),
      recordedGeometry: .init(width: 5, height: 6), recordedAspect: .init(width: 5, height: 6),
      cropTop: 0, cropLeft: 0, orientation: 8)
    #expect(throws: FujiJPEGValidationError.self) {
      try XT5ConversionCodec.validateFullSizeFineJPEG(data, expected: wrong)
    }
  }
}

/// Synthetic TIFF/MakerNote only; no actual image/profile/serial bytes are bundled.
struct JPEGQualityFixture {
  let jpeg: Data, exifSegment: Data, imageBody: Data
  let tiff = 12
  let exifPointer: Int, makerEntry: Int, maker: Int, qualityEntry: Int, qualityValue: Int
  init(
    quality: String = "FINE   ", make: String = "FUJIFILM", model: String = "X-T5",
    orientation: UInt16 = 8, little: Bool = true, thumbnailOrientation: UInt16? = nil,
    duplicateQuality: Bool = false, duplicateMaker: Bool = false, duplicateOrientation: Bool = false
  ) {
    func u16(_ v: UInt16, _ le: Bool) -> Data {
      Data(
        le
          ? [UInt8(truncatingIfNeeded: v), UInt8(v >> 8)]
          : [UInt8(v >> 8), UInt8(truncatingIfNeeded: v)])
    }
    func u32(_ v: UInt32, _ le: Bool) -> Data {
      Data((le ? [0, 8, 16, 24] : [24, 16, 8, 0]).map { UInt8(truncatingIfNeeded: v >> $0) })
    }
    var note = Data("FUJIFILM".utf8) + u32(12, true)
    let qualityCount = duplicateQuality ? 2 : 1
    note.append(u16(UInt16(qualityCount), true))
    let qualityBytes = Data(quality.utf8) + Data([0])
    let qualityOffset = 12 + 2 + 12 * qualityCount + 4
    for _ in 0..<qualityCount {
      note.append(
        u16(0x1000, true) + u16(2, true) + u32(UInt32(qualityBytes.count), true)
          + u32(UInt32(qualityOffset), true))
    }
    note.append(u32(0, true))
    note.append(qualityBytes)
    var b = Data(little ? [0x49, 0x49, 42, 0, 8, 0, 0, 0] : [0x4d, 0x4d, 0, 42, 0, 0, 0, 8])
    typealias Entry = (UInt16, UInt16, UInt32, Data)
    func ifd(_ entries: [Entry]) -> (Int, [Int], [Int], Int) {
      let at = b.count
      b.append(u16(UInt16(entries.count), little))
      b.append(Data(repeating: 0, count: entries.count * 12 + 4))
      var entryOffsets: [Int] = []
      var values: [Int] = []
      for (i, e) in entries.enumerated() {
        let o = at + 2 + i * 12
        entryOffsets.append(o)
        b.replaceSubrange(o..<o + 8, with: u16(e.0, little) + u16(e.1, little) + u32(e.2, little))
        if e.3.count <= 4 {
          b.replaceSubrange(o + 8..<o + 8 + e.3.count, with: e.3)
          values.append(o + 8)
        } else {
          if b.count % 2 != 0 { b.append(0) }
          let start = b.count
          b.append(e.3)
          b.replaceSubrange(o + 8..<o + 12, with: u32(UInt32(start), little))
          values.append(start)
        }
      }
      if b.count % 2 != 0 { b.append(0) }
      return (at, entryOffsets, values, at + 2 + entries.count * 12)
    }
    var primary: [Entry] = [
      (0x10f, 2, UInt32(make.utf8.count + 1), Data(make.utf8) + Data([0])),
      (0x110, 2, UInt32(model.utf8.count + 1), Data(model.utf8) + Data([0])),
      (0x112, 3, 1, u16(orientation, little)), (0x8769, 4, 1, u32(0, little)),
    ]
    if duplicateOrientation { primary.append((0x112, 3, 1, u16(orientation, little))) }
    let root = ifd(primary)
    var exif: [Entry] = [
      (0x927c, 7, UInt32(note.count), note), (0xa002, 4, 1, u32(4, little)),
      (0xa003, 4, 1, u32(6, little)),
    ]
    if duplicateMaker { exif.append((0x927c, 7, UInt32(note.count), note)) }
    let child = ifd(exif)
    b.replaceSubrange(root.1[3] + 8..<root.1[3] + 12, with: u32(UInt32(child.0), little))
    if let thumbnailOrientation {
      let thumb = ifd([(0x112, 3, 1, u16(thumbnailOrientation, little))])
      b.replaceSubrange(root.3..<root.3 + 4, with: u32(UInt32(thumb.0), little))
    }
    exifPointer = 12 + root.1[3] + 8
    makerEntry = 12 + child.1[0]
    maker = 12 + child.2[0]
    qualityEntry = maker + 14
    qualityValue = maker + qualityOffset
    let payload = Data([0x45, 0x78, 0x69, 0x66, 0, 0]) + b
    exifSegment = Data([0xff, 0xe1]) + u16(UInt16(payload.count + 2), false) + payload
    // Minimal structural JPEG. Integration uses the independent ImageIO-generated JPEG below.
    imageBody = Data([
      0xff, 0xc0, 0, 17, 8, 0, 6, 0, 4, 3, 1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1, 0xff, 0xda, 0, 12, 3,
      1, 0, 2, 0x11, 3, 0x11, 0, 63, 0, 0x11, 0xff, 0xd9,
    ])
    jpeg = Data([0xff, 0xd8]) + exifSegment + imageBody
  }
  func changed(_ offset: Int, bytes: [UInt8]) -> Data {
    var result = jpeg
    result.replaceSubrange(offset..<offset + bytes.count, with: bytes)
    return result
  }
  func inject(into image: Data) -> Data {
    var result = Data([0xff, 0xd8]) + exifSegment
    var p = 2
    while p < image.count {
      let marker = image[p + 1]
      if marker == 0xda {
        result.append(image[p...])
        break
      }
      let length = Int(image[p + 2]) * 256 + Int(image[p + 3])
      if marker != 0xe1
        || image.subdata(in: p + 4..<min(p + 10, image.count))
          != Data([0x45, 0x78, 0x69, 0x66, 0, 0])
      {
        result.append(image[p..<p + 2 + length])
      }
      p += 2 + length
    }
    return result
  }
}
