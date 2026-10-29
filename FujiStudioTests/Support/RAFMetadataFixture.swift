import Foundation
import Testing
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import FujiCameraCore

func rafMetadataFixture(model: String) throws -> LocalResource {
        let token = ResourceToken(assetID:"source",role:.alternateOriginal,contentTypeIdentifier:"com.fuji.raw-image",format:.raf,originalFilename:"test.RAF",discriminator:"fixture",sourceRevision:"revision-1")
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let jpeg = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil))
        let image = try #require(context.makeImage())
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: model]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        var bytes = Data(repeating: 0, count: 128)
        bytes.replaceSubrange(0..<16, with: Data("FUJIFILMCCD-RAW ".utf8))
        bytes.replaceSubrange(28..<(28 + model.utf8.count), with: Data(model.utf8))
        func big32(_ n: Int) -> Data { withUnsafeBytes(of: UInt32(n).bigEndian) { Data($0) } }
        func big16(_ n: Int) -> Data { withUnsafeBytes(of: UInt16(n).bigEndian) { Data($0) } }
        var directory = big32(5)
        for (tag, values) in [(0x100, [5196, 7872]), (0x110, [22, 72]), (0x111, [5152, 7728]),
                              (0x115, [2, 3]), (0x121, [5196, 7872])] {
            directory += big16(tag) + big16(4) + big16(values[0]) + big16(values[1])
        }
        bytes.replaceSubrange(84..<88, with: big32(128))
        bytes.replaceSubrange(88..<92, with: big32(jpeg.length))
        bytes.replaceSubrange(92..<96, with: big32(128 + jpeg.length))
        bytes.replaceSubrange(96..<100, with: big32(directory.count))
        bytes.replaceSubrange(100..<104, with: big32(128 + jpeg.length + directory.count))
        bytes.replaceSubrange(104..<108, with: big32(16))
        bytes += jpeg as Data
        bytes += directory
        bytes += Data(repeating: 0xab, count: 16)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".RAF")
        try bytes.write(to: url)
        return LocalResource(token: token, fileURL: url, checksum: try ResourceChecksum.sha256(url))
    }
