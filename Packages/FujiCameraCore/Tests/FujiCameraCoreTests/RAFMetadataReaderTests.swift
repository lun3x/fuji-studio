@testable import FujiCameraCore
import Foundation
import Testing
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

struct RAFMetadataReaderTests {
    @Test func verifiesRAFIdentityAndPreservesCropAndOrientationWithoutRAWDecode() throws {
        let local = try fixture(model: "X-T5")
        defer { try? FileManager.default.removeItem(at: local.fileURL) }
        let prepared = try RAFMetadataReader().prepare(local)
        #expect(prepared.metadata.cameraModel == "X-T5")
        #expect(prepared.metadata.containerGeometry == PixelSize(width: 7872, height: 5196))
        #expect(prepared.metadata.recordedGeometry == PixelSize(width: 7728, height: 5152))
        #expect(prepared.metadata.recordedAspect == PixelSize(width: 3, height: 2))
        #expect(prepared.metadata.orientation == 6)
        #expect(prepared.metadata.cropTop == 22)
        #expect(prepared.sourceID == "source")
        #expect(prepared.sourceRevision == "revision-1")
    }

    @Test func structuralReaderRetainsOtherModelWithoutAdmittingIt() throws {
        let local = try fixture(model: "X-T4")
        defer { try? FileManager.default.removeItem(at: local.fileURL) }
        #expect(try RAFMetadataReader().prepare(local).metadata.cameraModel == "X-T4")
        #expect(throws: CameraServiceError.unsupportedSource) { try XT5Adapter().validateSource(RAFMetadataReader().prepare(local).metadata) }
    }

    @Test func rejectsRenamedJPEGAndTruncatedRAF() throws {
        for bytes in [Data("not a RAF".utf8), Data("FUJIFILMCCD-RAW ".utf8)] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try bytes.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let local = LocalResource(token: token, fileURL: url, checksum: try ResourceChecksum.sha256(url))
            #expect(throws: ResourceError.self) { try RAFMetadataReader().prepare(local) }
        }
    }

    @Test func detectsFileMutationAfterMaterialization() throws {
        let local = try fixture(model: "X-T5")
        defer { try? FileManager.default.removeItem(at: local.fileURL) }
        try Data("modified".utf8).write(to: local.fileURL)
        #expect(throws: ResourceError.checksumMismatch) { try RAFMetadataReader().prepare(local) }
    }

    @Test func rejectsMissingOriginalRAWPayload() throws {
        let local = try fixture(model: "X-T5")
        defer { try? FileManager.default.removeItem(at: local.fileURL) }
        var bytes = try Data(contentsOf: local.fileURL)
        bytes.replaceSubrange(100..<108, with: Data(repeating: 0, count: 8))
        try bytes.write(to: local.fileURL)
        let changed = LocalResource(token: local.token, fileURL: local.fileURL,
                                    checksum: try ResourceChecksum.sha256(local.fileURL))
        #expect(throws: ResourceError.invalidRAF("Invalid RAW payload bounds")) {
            try RAFMetadataReader().prepare(changed)
        }
    }

    private var token: ResourceToken {
        ResourceToken(assetID: "source", role: .alternateOriginal, contentTypeIdentifier: "com.fuji.raw-image",
                      format: .raf, originalFilename: "test.RAF", discriminator: "fixture", sourceRevision: "revision-1")
    }

    private func fixture(model: String) throws -> LocalResource {
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
}
