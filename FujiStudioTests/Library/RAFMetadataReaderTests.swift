@testable import FujiCameraCore
import Foundation
import Testing
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
@testable import FujiStudio

struct RAFMetadataReaderTests {
    @Test func verifiesRAFIdentityAndPreservesCropAndOrientationWithoutRAWDecode() throws {
        let local = try rafMetadataFixture(model: "X-T5")
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
        let local = try rafMetadataFixture(model: "X-T4")
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
        let local = try rafMetadataFixture(model: "X-T5")
        defer { try? FileManager.default.removeItem(at: local.fileURL) }
        try Data("modified".utf8).write(to: local.fileURL)
        #expect(throws: ResourceError.checksumMismatch) { try RAFMetadataReader().prepare(local) }
    }

    @Test func rejectsMissingOriginalRAWPayload() throws {
        let local = try rafMetadataFixture(model: "X-T5")
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

}
