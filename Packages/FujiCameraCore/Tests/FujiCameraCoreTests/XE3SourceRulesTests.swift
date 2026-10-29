import Foundation
import Testing
@testable import FujiCameraCore

struct XE3SourceRulesTests {
    @Test func compressedXE3RecordedCropIsIndependentOfEmbeddedJPEG() throws {
        let m=RAWMetadata(cameraModel:"X-E3",containerGeometry:.init(width:6048,height:4038),recordedGeometry:.init(width:6000,height:4000),recordedAspect:.init(width:3,height:2),cropTop:21,cropLeft:16,orientation:1,compression:.lossless,bitDepth:14,rafVersion:"0130")
        try XE3SourceRules.validate(m)
        #expect(m.containerGeometry == PixelSize(width:6048,height:4038))
        #expect(m.recordedGeometry == PixelSize(width:6000,height:4000))
        #expect(m.cropTop == 21 && m.cropLeft == 16)
    }
    @Test(arguments:[1,8]) func uncompressedXE3UsesItsMeasuredContainer(_ orientation:Int) throws {
        let m=metadata(orientation:orientation)
        try XE3SourceRules.validate(m)
        #expect(m.containerGeometry == PixelSize(width:6160,height:4032))
        #expect(m.cropTop == 16 && m.cropLeft == 16)
    }
    @Test func unmeasuredEncodingAndOrientationNeverGainAdmission() throws {
        for (compression,bits,orientation):(RAFCompression,Int,Int) in [(.lossy,14,1),(.uncompressed,12,1),(.uncompressed,14,6)] {
            #expect(throws:CameraServiceError.unsupportedSource) { try XE3SourceRules.validate(metadata(compression:compression,bits:bits,orientation:orientation)) }
        }
        #expect(throws:CameraServiceError.unsupportedSource) { try XT5Adapter().validateSource(metadata()) }
    }
    private func metadata(compression:RAFCompression = .uncompressed,bits:Int=14,orientation:Int=8) -> RAWMetadata {
        .init(cameraModel:"X-E3",containerGeometry:.init(width:6160,height:4032),recordedGeometry:.init(width:6000,height:4000),recordedAspect:.init(width:3,height:2),cropTop:16,cropLeft:16,orientation:orientation,compression:compression,bitDepth:bits,rafVersion:"0130")
    }
}

extension XE3SourceRulesTests {
    @Test(arguments:[UInt32(0),2]) func parserReadsEncodingFromHeaderAndSensorIFD(_ compression:UInt32) throws {
        let resource=try xe3RAFFixture(compression:compression);defer { try? FileManager.default.removeItem(at:resource.fileURL) }
        let raw=try RAFMetadataReader().prepare(resource)
        #expect(raw.metadata.compression == (compression == 2 ? .lossless : .uncompressed))
        #expect(raw.metadata.bitDepth == 14 && raw.metadata.rafVersion == "0130")
        #expect(raw.metadata.recordedGeometry == PixelSize(width:6000,height:4000))
        try XE3SourceRules.validate(raw.metadata)
    }
    @Test func duplicateGeometryCannotSpoofMeasuredSourceClass() throws {
        let resource=try xe3RAFFixture(duplicateGeometry:true);defer { try? FileManager.default.removeItem(at:resource.fileURL) }
        #expect(throws:ResourceError.self) { try RAFMetadataReader().prepare(resource) }
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["FUJI_XE3_PRIVATE_SAMPLES"] != nil))
    func suppliedSevenSourcesMatchMeasuredEncodingClasses() throws {
        let root=URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["FUJI_XE3_PRIVATE_SAMPLES"]))
        for (sample,orientation) in [(80,1),(81,8),(82,1),(83,1),(84,8),(85,8),(86,8)] {
            let url=root.appendingPathComponent(String(format:"DSCF%04d.RAF",sample))
            let token=ResourceToken(assetID:"sample",role:.primaryOriginal,contentTypeIdentifier:"com.fujifilm.raw-image",format:.raf,originalFilename:url.lastPathComponent,discriminator:"sample")
            let metadata=try RAFMetadataReader().prepare(.init(token:token,fileURL:url,checksum:ResourceChecksum.sha256(url))).metadata
            #expect(metadata.compression == (sample < 83 ? .lossless : .uncompressed))
            #expect(metadata.bitDepth == 14 && metadata.orientation == orientation)
            try XE3SourceRules.validate(metadata)
        }
    }
}

extension XE3SourceRulesTests {
    @Test func recognizedModelDoesNotMakeOriginalViewingDependOnConversionGeometry() throws {
        let metadata=RAWMetadata(cameraModel:"X-T5",containerGeometry:.init(width:7872,height:5196),recordedGeometry:.init(width:6000,height:4000),recordedAspect:.init(width:3,height:2),cropTop:22,cropLeft:72,orientation:6)
        #expect(SourceCompatibility.detected(metadata) == .supported(model:"X-T5"))
        #expect(throws:CameraServiceError.unsupportedSource) { try XT5Adapter().validateSource(metadata) }
    }
}
