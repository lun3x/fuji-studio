import Foundation
import FujiCameraCore
import XCTest

@testable import FujiStudio

final class CaptureResolverTests: XCTestCase {
    func testSameCardPairUsesCompatibleFilenameAndCaptureMetadata() throws {
        let raw = CaptureFixture.object(1, .raf)
        let jpeg = CaptureFixture.object(2, .jpeg)
        let captures = resolve([jpeg, raw])

        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.availability, .pair)
        XCTAssertEqual(captures.first?.objects, [raw, jpeg])
        let noDirectory = [CaptureFixture.object(1, .raf, directory: nil),
                           CaptureFixture.object(2, .jpeg, directory: nil)]
        XCTAssertEqual(resolve(noDirectory).map(\.availability), [.pair])
        let croppedJPEG = CaptureFixture.object(2, .jpeg, dimensions: .init(width: 3000, height: 2000))
        let fullRAW = CaptureFixture.object(1, .raf, dimensions: .init(width: 6000, height: 4000))
        XCTAssertEqual(resolve([fullRAW, croppedJPEG]).map(\.availability), [.pair])
    }

    func testSplitCardPairNeedsCorroborationBeyondFilenameAndTimestamp() {
        let raw = CaptureFixture.object(1, .raf, dimensions: .init(width: 6000, height: 4000))
        let jpeg = CaptureFixture.object(2, .jpeg, storage: 2, directory: "DCIM/101_FUJI",
                                         dimensions: .init(width: 6000, height: 4000))
        let noCorroboration = CaptureFixture.object(2, .jpeg, storage: 2, directory: "DCIM/101_FUJI")
        let orientedRAW = CaptureFixture.object(1, .raf, orientation: 1)
        let orientationOnly = CaptureFixture.object(2, .jpeg, storage: 2, orientation: 1)

        XCTAssertEqual(resolve([raw, jpeg]).map(\.availability), [.pair])
        XCTAssertEqual(resolve([raw, noCorroboration]).map(\.availability), [.ambiguous, .ambiguous])
        XCTAssertEqual(resolve([orientedRAW, orientationOnly]).map(\.availability), [.ambiguous, .ambiguous])
    }

    func testDuplicateBasenamesNeverBecomeAnAutomaticPair() {
        let dimensions = PixelSize(width: 6000, height: 4000)
        let objects = [
            CaptureFixture.object(1, .raf, dimensions: dimensions),
            CaptureFixture.object(2, .jpeg, dimensions: dimensions),
            CaptureFixture.object(3, .jpeg, storage: 2, directory: "DCIM/101_FUJI", dimensions: dimensions)
        ]
        let captures = resolve(objects)

        XCTAssertEqual(captures.count, 3)
        XCTAssertEqual(captures.filter { $0.availability == .pair }.count, 0)
        XCTAssertEqual(captures.first { $0.objects.first?.format == .raf }?.availability, .ambiguous)
    }

    func testDuplicateBasenamesInDifferentFoldersDoNotPairOnTheSameCard() {
        let raw = CaptureFixture.object(1, .raf)
        let jpeg = CaptureFixture.object(2, .jpeg, directory: "DCIM/101_FUJI")
        XCTAssertEqual(resolve([raw, jpeg]).map(\.availability), [.ambiguous, .ambiguous])
    }

    func testSameTimestampBurstUsesCompatibleFilenames() {
        let raw = CaptureFixture.object(1, .raf)
        let jpeg = CaptureFixture.object(2, .jpeg, stem: "DSCF0002")
        XCTAssertEqual(Set(resolve([raw, jpeg]).map(\.availability)), [.rawOnly, .jpegOnly])
    }

    func testMissingOrConflictingMetadataCannotResolvePair() {
        for objects in [
            [CaptureFixture.object(1, .raf, date: nil), CaptureFixture.object(2, .jpeg, date: nil)],
            [CaptureFixture.object(1, .raf, date: "not-a-date"), CaptureFixture.object(2, .jpeg, date: "not-a-date")],
            [CaptureFixture.object(1, .raf, orientation: 1), CaptureFixture.object(2, .jpeg, orientation: 8)],
            [CaptureFixture.object(1, .raf), CaptureFixture.object(2, .jpeg, date: "20261114T190000Z")]
        ] {
            XCTAssertEqual(resolve(objects).map(\.availability), [.ambiguous, .ambiguous])
        }
    }

    func testUnavailableSecondCardPreservesUncertainty() {
        let raw = CaptureFixture.object(1, .raf)
        let jpeg = CaptureFixture.object(2, .jpeg, stem: "DSCF0002")
        let unavailable = WirelessStorageInventory(storage: [1: .complete, 2: .unavailable], rawExposure: .available)
        XCTAssertEqual(Set(CaptureResolver.resolve(objects: [raw, jpeg], inventory: unavailable).map(\.availability)),
                       [.ambiguous, .rawUnavailable])
    }

    func testUnknownRAWExposureIsNotVerifiedJPEGOnly() {
        let jpeg = CaptureFixture.object(2, .jpeg)
        for exposure in [WirelessRAWExposure.unknown, .unavailable] {
            let inventory = WirelessStorageInventory(storage: [1: .complete], rawExposure: exposure)
            XCTAssertEqual(CaptureResolver.resolve(objects: [jpeg], inventory: inventory).first?.availability,
                           .rawUnavailable)
        }
        XCTAssertEqual(resolve([jpeg]).first?.availability, .jpegOnly)
    }

    func testPendingCardKeepsEvenAnApparentlyMatchedPairInChecking() {
        let raw = CaptureFixture.object(1, .raf)
        let jpeg = CaptureFixture.object(2, .jpeg)
        let pending = WirelessStorageInventory(storage: [1: .complete, 2: .pending], rawExposure: .available)
        XCTAssertEqual(CaptureResolver.resolve(objects: [raw, jpeg], inventory: pending).map(\.availability),
                       [.checking, .checking])
    }

    func testPreviouslySeenMateOnUnavailableCardCannotBeAdmitted() {
        let raw = CaptureFixture.object(1, .raf, dimensions: .init(width: 6000, height: 4000))
        let jpeg = CaptureFixture.object(2, .jpeg, storage: 2, dimensions: raw.dimensions)
        let inventory = WirelessStorageInventory(storage: [1: .complete, 2: .unavailable], rawExposure: .available)
        XCTAssertFalse(CaptureResolver.resolve(objects: [raw, jpeg], inventory: inventory)
            .contains { $0.availability == .pair })
    }

    func testUndatedPlausibleMateKeepsAnApparentMatchAmbiguous() {
        let raw = CaptureFixture.object(1, .raf)
        let jpeg = CaptureFixture.object(2, .jpeg)
        let undated = CaptureFixture.object(3, .jpeg, date: nil)
        XCTAssertEqual(resolve([raw, jpeg, undated]).map(\.availability), [.ambiguous, .ambiguous, .ambiguous])
    }

    func testUnreportedOffsetKeepsSameWallTimeMatePlausible() {
        for (matchingDate, competingDate) in [
            ("20261114T180000Z", "20261114T180000"),
            ("20261114T180000", "20261114T180000Z")
        ] {
            let raw = CaptureFixture.object(1, .raf, date: matchingDate)
            let jpeg = CaptureFixture.object(2, .jpeg, date: matchingDate)
            let competitor = CaptureFixture.object(3, .jpeg, date: competingDate)
            XCTAssertEqual(resolve([raw, jpeg, competitor]).map(\.availability),
                           [.ambiguous, .ambiguous, .ambiguous])
            XCTAssertFalse(resolve([raw, competitor]).contains { $0.availability == .pair })
        }
    }

    func testDescriptiveIDsSurviveNewHandlesButChangeWhenCardEvidenceChanges() throws {
        let original = CaptureFixture.object(4, .raf, stem: "dscf0001", directory: "dcim\\100_fuji",
                                             reportedStorageID: 14)
        let reconnected = CaptureFixture.object(8, .raf, reportedStorageID: 14,
                                                session: CaptureFixture.otherSessionID)
        let swapped = CaptureFixture.object(4, .raf, reportedStorageID: 15,
                                            session: CaptureFixture.otherSessionID)
        let originalID = try XCTUnwrap(resolve([original]).first?.id)

        XCTAssertEqual(originalID, resolve([reconnected]).first?.id)
        XCTAssertNotEqual(originalID, resolve([swapped]).first?.id)
    }

    func testSameHandlesOnDifferentSessionsOrCamerasCannotPair() {
        let raw = CaptureFixture.object(1, .raf)
        let sameHandleNewSession = CaptureFixture.object(1, .jpeg, session: CaptureFixture.otherSessionID)
        let sameHandleOtherCamera = CaptureFixture.object(1, .jpeg, camera: WirelessCameraID())
        for other in [sameHandleNewSession, sameHandleOtherCamera] {
            XCTAssertEqual(Set(resolve([raw, other]).map(\.availability)), [.rawOnly, .jpegOnly])
        }
    }

    func testIdenticalEvidenceStaysInSeparateAmbiguousRows() {
        let raw = CaptureFixture.object(1, .raf)
        let duplicate = CaptureFixture.object(2, .raf)
        let captures = resolve([raw, duplicate, raw, CaptureFixture.object(3, .jpeg)])

        XCTAssertEqual(captures.count, 3)
        XCTAssertTrue(captures.allSatisfy { $0.availability == .ambiguous })
        XCTAssertEqual(Set(captures.map(\.rowID)).count, 3)
        XCTAssertEqual(Set(captures.filter { $0.objects.first?.format == .raf }.map(\.id)).count, 1)
        XCTAssertEqual(captures, resolve([CaptureFixture.object(3, .jpeg), duplicate, raw]))
    }

    private func resolve(_ objects: [WirelessObjectDescriptor]) -> [CameraCapture] {
        CaptureResolver.resolve(objects: objects, inventory: .init(storage: [1: .complete, 2: .complete],
                                                                  rawExposure: .available))
    }
}

enum CaptureFixture {
    static let cameraID = WirelessCameraID()
    static let sessionID = UUID()
    static let otherSessionID = UUID()
    static let identity = WirelessIdentity(cameraID: cameraID, model: .xt5, firmware: "4.32")

    static func object(
        _ handle: UInt32, _ format: WirelessObjectFormat, stem: String = "DSCF0001",
        storage: UInt32 = 1, directory: String? = "DCIM/100_FUJI", date: String? = "20261114T180000",
        length: UInt64 = 100, dimensions: PixelSize? = nil, orientation: Int? = nil,
        reportedStorageID: UInt32? = nil, thumbnail: Bool = true, session: UUID = sessionID,
        camera: WirelessCameraID = cameraID
    ) -> WirelessObjectDescriptor {
        let suffix: String
        switch format {
        case .raf: suffix = "RAF"
        case .jpeg: suffix = "JPG"
        case .other(0xb10b): suffix = "HEIF"
        default: suffix = "MOV"
        }
        return .init(cameraID: camera, sessionID: session, storageID: storage, handle: handle,
                     directory: directory, filename: "\(stem).\(suffix)", format: format, byteLength: length,
                     captureDate: date, dimensions: dimensions, orientation: orientation,
                     reportedStorageID: reportedStorageID, hasThumbnail: thumbnail)
    }
}
