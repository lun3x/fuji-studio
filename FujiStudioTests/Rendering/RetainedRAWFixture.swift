@testable import FujiCameraCore
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import FujiStudio

/// Synthetic framing and metadata only; pixel payload deliberately is not a decodable RAF.
struct RetainedRAWFixture {
    let root: URL, run: URL, hash: String
    init(directory: URL, paired: Bool = true) throws {
        root = directory; run = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let jpeg = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), [kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "X-T5"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        func big32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) } }
        func big16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).bigEndian) { Data($0) } }
        var bytes = Data(repeating: 0, count: 128)
        bytes.replaceSubrange(0..<16, with: Data("FUJIFILMCCD-RAW ".utf8))
        bytes.replaceSubrange(28..<32, with: Data("X-T5".utf8))
        var tags = big32(4)
        for (tag, values) in [(0x100, [5196, 7872]), (0x110, [22, 72]), (0x111, [5152, 7728]), (0x115, [2, 3])] {
            tags += big16(tag) + big16(4) + big16(values[0]) + big16(values[1])
        }
        for (offset, value) in [(84,128), (88,jpeg.length), (92,128+jpeg.length), (96,tags.count), (100,128+jpeg.length+tags.count), (104,16)] {
            bytes.replaceSubrange(offset..<(offset+4), with: big32(value))
        }
        bytes += jpeg as Data; bytes += tags; bytes += Data(repeating: 0xab, count: 16)
        let file = run.appendingPathComponent("source.RAF"); try bytes.write(to: file)
        hash = try ResourceChecksum.sha256(file)
        // Exact key shapes of the retained standalone A and paired B captures; values are synthetic.
        var manifest: [String: Any] = ["sourceID": paired ? "synthetic-pair" : "synthetic-standalone", "sourceRevision": "revision", "originalFilename": "synthetic.RAF",
            "resourceRole": paired ? "alternateOriginal" : "primaryOriginal", "sha256": hash, "pairedJPEGAvailable": paired,
            "cameraModel": "X-T5", "captureDate": "2020-01-01T00:00:00Z",
            "containerWidth": 7872, "containerHeight": 5196, "recordedWidth": 7728, "recordedHeight": 5152,
            "aspectWidth": 3, "aspectHeight": 2, "cropTop": 22, "cropLeft": 72, "orientation": 6]
        if paired {
            manifest.merge(["jpegSourceID": "synthetic-pair", "jpegSourceRevision": "revision", "jpegResourceRole": "primaryOriginal",
                "jpegOriginalFilename": "synthetic.JPG", "jpegDiscriminator": "paired-jpeg", "rafDiscriminator": "paired-raf", "compatibility": "xt5"]) { _, new in new }
        }
        try JSONSerialization.data(withJSONObject: manifest).write(to: run.appendingPathComponent("source-manifest.json"))
        try JSONSerialization.data(withJSONObject: ["sourceSHA256": hash]).write(to: run.appendingPathComponent("protocol-manifest.json"))
    }
}
