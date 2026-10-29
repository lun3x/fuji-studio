import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import Testing
@testable import FujiCameraCore

func xe3RAFFixture(compression:UInt32=2,bits:Int=14,orientation:Int=8,duplicateGeometry:Bool=false) throws -> LocalResource {
    let cg=try #require(CGContext(data:nil,width:4,height:6,bitsPerComponent:8,bytesPerRow:16,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue))
    let jpeg=NSMutableData()
    let actualDestination=try #require(CGImageDestinationCreateWithData(jpeg,UTType.jpeg.identifier as CFString,1,nil))
    CGImageDestinationAddImage(actualDestination,try #require(cg.makeImage()),[kCGImagePropertyOrientation:orientation,kCGImagePropertyTIFFDictionary:[kCGImagePropertyTIFFModel:"X-E3"]] as CFDictionary)
    #expect(CGImageDestinationFinalize(actualDestination))
    func be16(_ n:Int)->Data { withUnsafeBytes(of:UInt16(n).bigEndian) { Data($0) } }
    func be32(_ n:Int)->Data { withUnsafeBytes(of:UInt32(n).bigEndian) { Data($0) } }
    func le16(_ n:Int)->Data { withUnsafeBytes(of:UInt16(n).littleEndian) { Data($0) } }
    func le32(_ n:Int)->Data { withUnsafeBytes(of:UInt32(n).littleEndian) { Data($0) } }
    let width=compression == 2 ? 6048 : 6160, height=compression == 2 ? 4038 : 4032, top=compression == 2 ? 21 : 16
    var tags=[(0x100,[height,width]),(0x110,[top,16]),(0x111,[4000,6000]),(0x115,[2,3])]
    if duplicateGeometry { tags.append(tags[0]) }
    var directory=be32(tags.count)
    for (tag,values) in tags { directory += be16(tag)+be16(4)+be16(values[0])+be16(values[1]) }
    var sensor=Data([0x49,0x49,42,0])+le32(8)+le16(1)+le16(0xf000)+le16(13)+le32(1)+le32(26)+le32(0)
    sensor += le16(3)
    for (tag,n) in [(0xf001,width),(0xf002,height),(0xf003,bits)] { sensor += le16(tag)+le16(4)+le32(1)+le32(n) }
    sensor += le32(0)
    var bytes=Data(repeating:0,count:128)
    bytes.replaceSubrange(0..<16,with:Data("FUJIFILMCCD-RAW ".utf8));bytes.replaceSubrange(28..<32,with:Data("X-E3".utf8));bytes.replaceSubrange(60..<64,with:Data("0130".utf8))
    for (offset,n) in [(84,128),(88,jpeg.length),(92,128+jpeg.length),(96,directory.count),(100,128+jpeg.length+directory.count),(104,sensor.count),(108,Int(compression))] { bytes.replaceSubrange(offset..<offset+4,with:be32(n)) }
    bytes += jpeg as Data;bytes += directory;bytes += sensor
    let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".RAF");try bytes.write(to:url)
    let token=ResourceToken(assetID:"xe3-source",role:.primaryOriginal,contentTypeIdentifier:"com.fujifilm.raw-image",format:.raf,originalFilename:"synthetic.RAF",discriminator:"xe3",sourceRevision:"v1")
    return LocalResource(token:token,fileURL:url,checksum:try ResourceChecksum.sha256(url))
}
