import Foundation
import FujiCameraCore
import XCTest
@testable import FujiStudio

@MainActor
final class OriginalImportValidatorTests: XCTestCase {
    func testXE3AutoSaveStagesAndRevalidatesRAWWhenObjectInfoOmitsDimensions() async throws {
        let fixture = try ImportFileFixture(model: .xe3)
        defer { fixture.cleanUp() }
        let store = try ImportStagingStore(root: fixture.root)
        let raw = WirelessObjectDescriptor(cameraID: fixture.camera.cameraID, sessionID: fixture.sessionID,
            storageID: 1, handle: 1, directory: nil, filename: "DSCF0001.RAF", format: .raf,
            byteLength: UInt64(fixture.raf.count), captureDate: fixture.objectDate, dimensions: nil, orientation: 1)
        let jpeg = fixture.object()
        let objects = [raw, jpeg]
        let selection = ImportSelection(captureID: .init(describing: objects), camera: fixture.camera,
                                        descriptors: objects, policy: .pair)
        let staged = try await store.write(object: raw, session: ImportFileSession(bytes: fixture.raf, mode: .autoSave))
        let companion = try await store.write(object: jpeg, session: ImportFileSession(bytes: fixture.jpeg, mode: .autoSave))
        let validated = try OriginalImportValidator(staging: store).validate(
            selection, originals: [staged, companion], importDate: .distantPast)
        XCTAssertEqual(validated.originals.first?.metadata.dimensions, .init(width: 7728, height: 5152))
        XCTAssertEqual(staged.sha256, ResourceChecksum.sha256(fixture.raf))
        await assertImportThrows {
            _ = try await store.write(object: raw, session: ImportFileSession(bytes: fixture.raf, mode: .phone))
        }
    }

    func testXT5DiagnosticComparesUnzonedObjectInfoAsUTCWithEmbeddedOffset() throws {
        for (offset, reported) in [("+01:00", "20200102T020405"), ("-05:00", "20200102T080405"),
                                   ("+05:30", "20200101T213405")] {
            let fixture = try ImportFileFixture(rawOffset: offset, objectDate: reported)
            defer { fixture.cleanUp() }
            try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
            let file = fixture.root.appendingPathComponent("source.raf")
            try fixture.raf.write(to: file)
            let metadata = try OriginalImportValidator.inspect(file: file, object: fixture.object(.raf))
            XCTAssertNoThrow(try OriginalImportValidator.checkDiagnosticCaptureTime(metadata, object: fixture.object(.raf)))
        }
    }

    func testXT5DiagnosticRejectsDifferentInstantEvenWhenWallClockMatches() throws {
        let fixture = try ImportFileFixture(rawOffset: "+01:00", objectDate: "20200102T030405")
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let file = fixture.root.appendingPathComponent("source.raf")
        try fixture.raf.write(to: file)
        let metadata = try OriginalImportValidator.inspect(file: file, object: fixture.object(.raf))
        XCTAssertThrowsError(try OriginalImportValidator.checkDiagnosticCaptureTime(metadata, object: fixture.object(.raf))) {
            XCTAssertEqual($0 as? OriginalImportError, .validation(.captureTimeMismatch))
        }
    }

    func testXT5MissingEXIFOffsetUsesCameraUTCTime() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let store = try ImportStagingStore(root: fixture.root)
        let originals = try await originals(fixture, store: store)
        let frozenDate = Date(timeIntervalSince1970: 1_700_000_000)
        let validated = try OriginalImportValidator(staging: store).validate(
            fixture.selection(), originals: originals, importDate: frozenDate)
        XCTAssertEqual(validated.metadata.creationDate, Date(timeIntervalSince1970: 1_577_934_245))
        XCTAssertEqual(validated.metadata.dateSource, .objectInfo)
        XCTAssertNil(validated.metadata.location)
        XCTAssertEqual(originals[0].metadata.captureWallTime, "20200102T030405")
        XCTAssertEqual(try ResourceChecksum.sha256(store.fileURL(for: originals[0])), ResourceChecksum.sha256(fixture.raf))
        XCTAssertEqual(try ResourceChecksum.sha256(store.fileURL(for: originals[1])), ResourceChecksum.sha256(fixture.jpeg))
        XCTAssertEqual(validated.originals[1].metadata.dimensions, .init(width: 6, height: 4))
    }

    func testEmbeddedExplicitOffsetAndCoordinatesArePreserved() async throws {
        let fixture = try ImportFileFixture(jpegOffset: "+02:00", rawOffset: "+02:00", location: true)
        defer { fixture.cleanUp() }
        let store = try ImportStagingStore(root: fixture.root)
        let originals = try await originals(fixture, store: store)
        let validated = try OriginalImportValidator(staging: store).validate(
            fixture.selection(), originals: originals, importDate: .distantFuture)
        XCTAssertEqual(validated.metadata.creationDate, Date(timeIntervalSince1970: 1_577_927_045))
        XCTAssertEqual(validated.metadata.dateSource, .embedded)
        XCTAssertEqual(validated.metadata.location, .init(latitude: 52.25, longitude: -4.5))
    }

    func testObjectInfoExplicitOffsetIsUsedWhenEmbeddedOffsetIsMissing() async throws {
        let fixture = try ImportFileFixture(objectDate: "20200102T030405+0200")
        defer { fixture.cleanUp() }
        let store = try ImportStagingStore(root: fixture.root)
        let originals = try await originals(fixture, store: store)
        let validated = try OriginalImportValidator(staging: store).validate(
            fixture.selection(), originals: originals, importDate: .distantFuture)
        XCTAssertEqual(validated.metadata.creationDate, Date(timeIntervalSince1970: 1_577_927_045))
        XCTAssertEqual(validated.metadata.dateSource, .objectInfo)
    }

    func testRejectsMismatchedPairMetadataAndIncompletePair() async throws {
        let fixture = try ImportFileFixture(jpegDate: "2020:01:02 04:04:05")
        defer { fixture.cleanUp() }
        let store = try ImportStagingStore(root: fixture.root)
        let originals = try await originals(fixture, store: store)
        let validator = OriginalImportValidator(staging: store)
        XCTAssertThrowsError(try validator.validate(fixture.selection(), originals: originals, importDate: .distantFuture))
        XCTAssertThrowsError(try validator.validate(fixture.selection(), originals: [originals[0]], importDate: .distantFuture))
    }

    func testRejectsIncorrectSignaturesAndReportedDimensions() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let store = try ImportStagingStore(root: fixture.root)
        var corruptRAF = fixture.raf
        corruptRAF[0] = 0
        var corruptJPEG = fixture.jpeg
        corruptJPEG[0] = 0
        for (object, bytes) in [(fixture.object(.raf), corruptRAF), (fixture.object(), corruptJPEG),
                               (fixture.object(dimensions: .init(width: 8, height: 4)), fixture.jpeg)] {
            await assertImportThrows {
                _ = try await store.write(object: object, session: ImportFileSession(bytes: bytes))
            }
        }
    }

    func testRevalidationRejectsMatchingFingerprintWithoutIndependentSensorPayload() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let store = try ImportStagingStore(root: fixture.root)
        let staged = try await store.write(object: fixture.object(.raf), session: ImportFileSession(bytes: fixture.raf))
        let bytes = fixture.rafWithoutSensorPayload
        let object = fixture.object(.raf, byteLength: UInt64(bytes.count))
        try bytes.write(to: store.fileURL(for: staged))
        let recorded = StagedOriginal(relativePath: staged.relativePath,
            fingerprint: .init(role: .raf, originalFilename: object.filename, byteCount: object.byteLength,
                               sha256: ResourceChecksum.sha256(bytes)),
            metadata: staged.metadata, descriptor: object, verifiedTransferMode: staged.verifiedTransferMode)
        let selection = ImportSelection(captureID: .init(describing: [object]), camera: fixture.camera,
                                        descriptors: [object], policy: .rawOnly)

        XCTAssertThrowsError(try OriginalImportValidator(staging: store).validate(
            selection, originals: [recorded], importDate: .distantPast))
    }

    private func originals(_ fixture: ImportFileFixture, store: ImportStagingStore) async throws -> [StagedOriginal] {
        let raw = try await store.write(object: fixture.object(.raf), session: ImportFileSession(bytes: fixture.raf))
        let jpeg = try await store.write(object: fixture.object(), session: ImportFileSession(bytes: fixture.jpeg))
        return [raw, jpeg]
    }
}
