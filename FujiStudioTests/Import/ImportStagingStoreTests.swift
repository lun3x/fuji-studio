import CoreGraphics
import Foundation
import FujiCameraCore
import ImageIO
import Synchronization
import UniformTypeIdentifiers
import XCTest
@testable import FujiStudio

@MainActor
final class ImportStagingStoreTests: XCTestCase {
    func testCameraFilenamesNeverDetermineLocalPaths() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let store = try ImportStagingStore(root: fixture.root)
        for filename in ["../escape.JPG", "/absolute.JPG"] {
            let object = fixture.object(filename: filename)
            let original = try await store.write(object: object, session: ImportFileSession(bytes: fixture.jpeg))
            let url = try store.fileURL(for: original)
            XCTAssertEqual(url.deletingLastPathComponent().resolvingSymlinksInPath(),
                           fixture.root.resolvingSymlinksInPath())
            XCTAssertEqual(original.originalFilename, filename)
            XCTAssertFalse(url.lastPathComponent.contains("escape"))
            XCTAssertFalse(url.lastPathComponent.contains("absolute"))
            XCTAssertEqual(original.sha256, ResourceChecksum.sha256(fixture.jpeg))
        }
    }

    func testUnknownOverflowingShortLongAndUnverifiedTransfersLeaveNoFiles() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let store = try ImportStagingStore(root: fixture.root)
        for length in [0, UInt64.max, UInt64(fixture.jpeg.count - 1), UInt64(fixture.jpeg.count + 1)] {
            let object = fixture.object(byteLength: length)
            await assertImportThrows {
                _ = try await store.write(object: object, session: ImportFileSession(bytes: fixture.jpeg))
            }
        }
        await assertImportThrows {
            _ = try await store.write(object: fixture.object(), session: ImportFileSession(bytes: fixture.jpeg, verified: false))
        }
        await assertImportThrows {
            _ = try await store.write(object: fixture.object(.raf, byteLength: 0), session: ImportFileSession(bytes: fixture.raf))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
        XCTAssertThrowsError(try ImportStagingStore.requiredCapacity(for: [UInt64.max]))
        XCTAssertThrowsError(try ImportStagingStore.requiredCapacity(for: [0]))
        XCTAssertEqual(try ImportStagingStore.requiredCapacity(for: [1, 2]), 67_108_870)
    }

    func testDisconnectRestartsPartialAndCompleteFileUsesFreshMatchingObject() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let store = try ImportStagingStore(root: fixture.root)
        let object = fixture.object()
        await assertImportThrows {
            _ = try await store.write(object: object, session: ImportFileSession(bytes: fixture.jpeg, interrupt: true))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
        let original = try await store.write(object: object, session: ImportFileSession(bytes: fixture.jpeg))
        let fresh = fixture.object(sessionID: UUID(), handle: 47)
        XCTAssertEqual(try store.reuse(original, frozen: object, matching: fresh), original)
        XCTAssertThrowsError(try store.reuse(original, frozen: object, matching: fixture.object(handle: 47, filename: "CHANGED.JPG")))
        try Data(repeating: 0, count: fixture.jpeg.count).write(to: store.fileURL(for: original))
        XCTAssertThrowsError(try store.reuse(original, frozen: object, matching: fresh))
    }

    func testDiskFullWhileWritingLeavesCompleteOriginalIntact() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let normal = try ImportStagingStore(root: fixture.root)
        let retained = try await normal.write(object: fixture.object(), session: ImportFileSession(bytes: fixture.jpeg))
        let chunkCount = Mutex(0)
        let fault = try ImportStagingStore(root: fixture.root, beforeChunkWrite: {
            try chunkCount.withLock {
                $0 += 1
                if $0 == 2 { throw POSIXError(.ENOSPC) }
            }
        })
        await assertImportThrows {
            _ = try await fault.write(object: fixture.object(), session: ImportFileSession(bytes: fixture.jpeg))
        }
        XCTAssertEqual(chunkCount.withLock { $0 }, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [retained.relativePath])
        XCTAssertEqual(try ResourceChecksum.sha256(normal.fileURL(for: retained)), retained.sha256)
    }

    func testEscapingAndSymlinkPathsDoNotResolve() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let store = try ImportStagingStore(root: fixture.root)
        let original = try await store.write(object: fixture.object(), session: ImportFileSession(bytes: fixture.jpeg))
        XCTAssertThrowsError(try store.fileURL(forRelativePath: "../" + original.relativePath))
        XCTAssertThrowsError(try store.fileURL(forRelativePath: "/" + original.relativePath))
        let destination = try store.fileURL(for: original)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: fixture.root.deletingLastPathComponent())
        XCTAssertThrowsError(try store.fileURL(for: original))
    }

    func testInterruptedPartialCleanupRefusesDirectoriesAndOriginalRemovalCanBeRetried() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let store = try ImportStagingStore(root: fixture.root)
        let original = try await store.write(object: fixture.object(), session: ImportFileSession(bytes: fixture.jpeg))
        let partial = fixture.root.appendingPathComponent(UUID().uuidString + ".part")
        try Data([1]).write(to: partial)
        try store.removeInterruptedDownloads()
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.removeInterruptedDownloads())
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        try store.remove(original)
        try store.remove(original)
    }
}

@MainActor
func assertImportThrows(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await operation()
        XCTFail("Expected import to fail", file: file, line: line)
    } catch {}
}

struct ImportFileSession: WirelessTransferSession {
    let bytes: Data
    var verified = true
    var interrupt = false

    func open() async throws -> WirelessIdentity { .init(cameraID: .init(), model: .xt5, firmware: "4.32") }
    func capabilities() async throws -> WirelessCapabilities {
        .init(mode: .xApp, rawExposure: .available, storageIDs: [1], originalSizeVerified: verified, evidenceID: "test")
    }
    func enumerate() async throws -> AsyncThrowingStream<WirelessInventoryBatch, Error> { .init { $0.finish() } }
    func thumbnail(_ object: WirelessObjectDescriptor) async throws -> Data { throw WirelessFailure.unsupportedProtocol }
    func download(_ object: WirelessObjectDescriptor, to sink: @escaping @Sendable (Data) async throws -> Void) async throws {
        let midpoint = bytes.count / 2
        try await sink(Data(bytes.prefix(midpoint)))
        if interrupt { throw WirelessFailure.connectionLost }
        try await sink(Data(bytes.dropFirst(midpoint)))
    }
    func close() async throws {}
}

struct ImportFileFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let camera = WirelessIdentity(cameraID: .init(), model: .xt5, firmware: "4.32",
                                  protocolPeerKey: .init(bytes: Data("camera-evidence-fixture".utf8)))
    let sessionID = UUID()
    let jpeg: Data
    let raf: Data
    let objectDate: String?

    init(jpegDate: String = "2020:01:02 03:04:05", jpegOffset: String? = nil,
         rawDate: String = "2020:01:02 03:04:05", rawOffset: String? = nil,
         objectDate: String? = "20200102T030405", location: Bool = false) throws {
        self.objectDate = objectDate
        jpeg = try Self.makeJPEG(width: 6, height: 4, date: jpegDate, offset: jpegOffset, location: location)
        let preview = try Self.makeJPEG(width: 2, height: 2, date: rawDate, offset: rawOffset, location: location)
        func big32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) } }
        func big16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).bigEndian) { Data($0) } }
        var bytes = Data(repeating: 0, count: 128)
        bytes.replaceSubrange(0..<16, with: Data("FUJIFILMCCD-RAW ".utf8))
        bytes.replaceSubrange(28..<32, with: Data("X-T5".utf8))
        var tags = big32(4)
        for (tag, values) in [(0x100, [5196, 7872]), (0x110, [22, 72]), (0x111, [5152, 7728]), (0x115, [2, 3])] {
            tags += big16(tag) + big16(4) + big16(values[0]) + big16(values[1])
        }
        for (offset, value) in [(84, 128), (88, preview.count), (92, 128 + preview.count),
                                (96, tags.count), (100, 128 + preview.count + tags.count), (104, 16)] {
            bytes.replaceSubrange(offset..<(offset + 4), with: big32(value))
        }
        bytes += preview + tags + Data(repeating: 0xab, count: 16)
        raf = bytes
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    func object(_ format: WirelessObjectFormat = .jpeg, sessionID: UUID? = nil, handle: UInt32? = nil,
                filename: String? = nil, byteLength: UInt64? = nil, dimensions: PixelSize? = nil) -> WirelessObjectDescriptor {
        .init(cameraID: camera.cameraID, sessionID: sessionID ?? self.sessionID, storageID: 1,
              handle: handle ?? (format == .raf ? 1 : 2), directory: "DCIM/100_FUJI",
              filename: filename ?? (format == .raf ? "DSCF0001.RAF" : "DSCF0001.JPG"), format: format,
              byteLength: byteLength ?? UInt64(format == .raf ? raf.count : jpeg.count),
              captureDate: objectDate,
              dimensions: dimensions ?? (format == .raf ? .init(width: 7728, height: 5152) : .init(width: 6, height: 4)),
              orientation: 1)
    }

    func selection(pair: Bool = true) -> ImportSelection {
        let descriptors = pair ? [object(.raf), object()] : [object(.raf)]
        return .init(captureID: .init(describing: descriptors), camera: camera, descriptors: descriptors,
                     policy: pair ? .pair : .rawOnly)
    }

    private static func makeJPEG(width: Int, height: Int, date: String, offset: String?, location: Bool) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let jpeg = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil))
        var exif: [String: Any] = [kCGImagePropertyExifDateTimeOriginal as String: date]
        if let offset { exif["OffsetTimeOriginal"] = offset }
        var properties: [String: Any] = [
            kCGImagePropertyOrientation as String: 1,
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "FUJIFILM",
                                                      kCGImagePropertyTIFFModel as String: "X-T5"],
            kCGImagePropertyExifDictionary as String: exif
        ]
        if location {
            properties[kCGImagePropertyGPSDictionary as String] = [
                kCGImagePropertyGPSLatitude as String: 52.25, kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 4.5, kCGImagePropertyGPSLongitudeRef as String: "W"
            ]
        }
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return jpeg as Data
    }
}
