import Foundation
import Testing
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
@testable import FujiCameraCore
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
