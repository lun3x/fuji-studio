@testable import FujiCameraCore
import Foundation
import Testing
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
@testable import FujiStudio

struct XT5ObjectObservationTests {
    @Test func readsObjectMetadataWithoutPublishingNamesOrClaimingOwnership() throws {
        let info = try FujiConversionCodec.objectInfo(ObjectObservationFixture.info())
        #expect(info.storageID == 0x10001)
        #expect(info.format == 0x3801)
        #expect(info.byteCount == 1234)
        #expect(info.width == 7728 && info.height == 5152)
        #expect(info.parent == 9)
        #expect(info.protection == 0)
    }
    @Test func objectMetadataRejectsEveryTruncationAndTrailingData() throws {
        let valid = ObjectObservationFixture.info()
        for end in 0..<valid.count {
            #expect(throws: (any Error).self) { try FujiConversionCodec.objectInfo(Data(valid.prefix(end))) }
        }
        #expect(throws: (any Error).self) { try FujiConversionCodec.objectInfo(valid + Data([0])) }
        var malformed = valid; malformed[52] = 255
        #expect(throws: (any Error).self) { try FujiConversionCodec.objectInfo(malformed) }
    }
    @Test func storageMetadataPreservesTypeAndAccessWithoutInferringTemporaryOwnership() throws {
        let value = try FujiConversionCodec.storageInfo(ObjectObservationFixture.storage())
        #expect(value.storageType == 4)
        #expect(value.filesystemType == 2)
        #expect(value.access == 0)
        #expect(value.capacity == 8_000_000)
        let bytes = ObjectObservationFixture.storage()
        for end in 0..<bytes.count { #expect(throws: (any Error).self) { try FujiConversionCodec.storageInfo(Data(bytes.prefix(end))) } }
        #expect(throws: (any Error).self) { try FujiConversionCodec.storageInfo(bytes + Data([0])) }
    }
    @Test func JPEGObservationReportsPixelsOrientationAndContextWithoutQualityInference() throws {
        let jpeg = try ObjectObservationFixture.jpeg()
        let observation = try FujiConversionCodec.jpegObservation(jpeg, expected: ObjectObservationFixture.metadata)
        #expect(observation.width == 4 && observation.height == 6)
        #expect(observation.orientation == 8)
        #expect(observation.modelMatches)
        #expect(observation.recordedGeometryMatches)
        #expect(observation.orientationMatches)
        #expect(!observation.fineQualityValidated)
        let wrong = RAWMetadata(cameraModel: "X-T5", containerGeometry: PixelSize(width: 7728,height: 5152), recordedGeometry: PixelSize(width: 7728,height: 5152), recordedAspect: PixelSize(width: 3,height: 2), cropTop: 0,cropLeft: 0,orientation: 1)
        let different = try FujiConversionCodec.jpegObservation(jpeg, expected: wrong)
        #expect(!different.recordedGeometryMatches && !different.orientationMatches)
        #expect(throws: (any Error).self) { try FujiConversionCodec.jpegObservation(Data(jpeg.dropLast(2)), expected: wrong) }
        #expect(throws: (any Error).self) { try FujiConversionCodec.jpegObservation(Data([1,2,3]), expected: wrong) }
    }
}

enum ObjectObservationFixture {
    static let metadata = RAWMetadata(cameraModel: "X-T5", containerGeometry: PixelSize(width: 4,height: 6), recordedGeometry: PixelSize(width: 4,height: 6), recordedAspect: PixelSize(width: 2,height: 3), cropTop: 0,cropLeft: 0,orientation: 8)
    static func word(_ value: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    static func info(format: UInt16 = 0x3801, byteCount: UInt32 = 1234) -> Data {
        var b = Data(repeating: 0,count: 52)
        b.replaceSubrange(0..<4,with: word(0x10001)); b.replaceSubrange(4..<6,with: ProtocolProbeFixtures.word(format))
        b.replaceSubrange(8..<12,with: word(byteCount)); b.replaceSubrange(26..<30,with: word(7728)); b.replaceSubrange(30..<34,with: word(5152)); b.replaceSubrange(38..<42,with: word(9))
        b += ProtocolProbeFixtures.string("PRIVATE.JPG")
        for _ in 0..<3 { b.append(0) }
        return b
    }
    static func storage() -> Data {
        var b = Data([4,0,2,0,0,0]); b += word(8_000_000); b += word(0); b += word(4_000_000); b += word(0); b += word(10)
        b += ProtocolProbeFixtures.string("PRIVATE STORAGE"); b.append(0)
        return b
    }
    static func jpeg() throws -> Data {
        let context = try #require(CGContext(data: nil,width: 4,height: 6,bitsPerComponent: 8,bytesPerRow: 16,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes,UTType.jpeg.identifier as CFString,1,nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), [kCGImagePropertyOrientation: 8,kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "X-T5"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return bytes as Data
    }
}
