import Foundation
import FujiCameraCore
import XCTest
@testable import FujiStudio

@MainActor
final class OriginalImportValidatorTests: XCTestCase {
    func testMissingTimezoneUsesFrozenImportDate() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let store = try ImportStagingStore(root: fixture.root)
        let originals = try await originals(fixture, store: store)
        let frozenDate = Date(timeIntervalSince1970: 1_700_000_000)
        let validated = try OriginalImportValidator(staging: store).validate(
            fixture.selection(), originals: originals, importDate: frozenDate)
        XCTAssertEqual(validated.metadata.creationDate, frozenDate)
        XCTAssertEqual(validated.metadata.dateSource, .importTimeMissingOffset)
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

    private func originals(_ fixture: ImportFileFixture, store: ImportStagingStore) async throws -> [StagedOriginal] {
        let raw = try await store.write(object: fixture.object(.raf), session: ImportFileSession(bytes: fixture.raf))
        let jpeg = try await store.write(object: fixture.object(), session: ImportFileSession(bytes: fixture.jpeg))
        return [raw, jpeg]
    }
}
