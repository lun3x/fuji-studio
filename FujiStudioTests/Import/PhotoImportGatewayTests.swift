import Foundation
import FujiCameraCore
import Photos
import XCTest
@testable import FujiStudio

@MainActor
final class PhotoImportGatewayTests: XCTestCase {
    func testPairCreatesOneAssetWithJPEGPrimaryAndRAFAlternate() async throws {
        let fixture = try ImportFileFixture(location: true)
        defer { fixture.cleanUp() }
        let (staging, capture) = try await fixture.validatedForPhotos()
        let library = PhotoImportCreationSpy()
        let gateway = NativePhotoImportGateway(staging: staging, creation: library)
        let journal = try ImportJournal(root: fixture.root.appendingPathComponent("journal"))
        var job = try ImportJob(selections: [capture.selection], importDate: capture.metadata.creationDate)
        job.captures[0].originals = capture.originals
        job.captures[0].stage = .submitting
        let saved = try await journal.save(job)
        let writer = journal.placeholderWriter

        let outcome = await gateway.create(capture) { assetID in
            try writer.persistPlaceholder(jobID: saved.id, captureID: capture.selection.captureID, assetID: assetID)
        }

        XCTAssertEqual(outcome, .submitted(assetID: "created-asset"))
        let reloaded = try await journal.loadJobs()
        XCTAssertEqual(reloaded.first?.captures.first?.placeholderAssetID, "created-asset")
        XCTAssertEqual(library.requests.count, 1)
        XCTAssertEqual(library.supportedTypes, [[.photo, .alternatePhoto]])
        let request = try XCTUnwrap(library.requests.first)
        XCTAssertEqual(request.resources.map(\.type), [.photo, .alternatePhoto])
        XCTAssertEqual(request.resources.map(\.filename), ["DSCF0001.JPG", "DSCF0001.RAF"])
        XCTAssertEqual(request.resources.map(\.shouldMoveFile), [false, false])
        XCTAssertTrue(request.prefersJPEG)
        XCTAssertEqual(request.metadata.creationDate, Date(timeIntervalSince1970: 1_577_934_245))
        XCTAssertEqual(request.metadata.location, .init(latitude: 52.25, longitude: -4.5))
        XCTAssertEqual(try Data(contentsOf: request.resources[0].fileURL), fixture.jpeg)
        XCTAssertEqual(try Data(contentsOf: request.resources[1].fileURL), fixture.raf)
        // The injected native boundary exposes only creation. No source, album, deletion
        // or Update original in Photos setting participates in this API.
    }

    func testStandaloneRAFUsesOnePrimaryResource() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let (staging, capture) = try await fixture.validatedForPhotos(pair: false)
        let library = PhotoImportCreationSpy(access: .limited)

        let outcome = await NativePhotoImportGateway(staging: staging, creation: library).create(capture) { _ in }

        XCTAssertEqual(outcome, .submitted(assetID: "created-asset"))
        XCTAssertEqual(library.requests.count, 1)
        XCTAssertEqual(library.supportedTypes, [[.photo]])
        let request = try XCTUnwrap(library.requests.first)
        XCTAssertEqual(request.resources.map(\.type), [.photo])
        XCTAssertEqual(request.resources.map(\.filename), ["DSCF0001.RAF"])
        XCTAssertFalse(request.prefersJPEG)
    }

    func testPreflightRejectionNeverIssuesCreation() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let (staging, capture) = try await fixture.validatedForPhotos()
        for (library, failure): (PhotoImportCreationSpy, PhotoImportFailure) in [
            (.init(access: .notDetermined), .authorization), (.init(access: .denied), .authorization),
            (.init(available: false), .unavailable), (.init(supports: false), .invalidResource)
        ] {
            let outcome = await NativePhotoImportGateway(staging: staging, creation: library).create(capture) { _ in
                XCTFail("Rejected save allocated a placeholder")
            }
            XCTAssertEqual(outcome, .rejected(failure))
            XCTAssertTrue(library.requests.isEmpty)
        }

        let library = PhotoImportCreationSpy()
        try FileManager.default.removeItem(at: staging.fileURL(for: capture.originals[1]))
        let outcome = await NativePhotoImportGateway(staging: staging, creation: library).create(capture) { _ in }
        XCTAssertEqual(outcome, .rejected(.invalidResource))
        XCTAssertTrue(library.requests.isEmpty, "Losing a pair mate must never fall back to RAW-only")
    }

    func testDurablePlaceholderFailureLeavesPossiblyCommittedSaveUncertain() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let (staging, capture) = try await fixture.validatedForPhotos()
        let library = PhotoImportCreationSpy()

        let outcome = await NativePhotoImportGateway(staging: staging, creation: library).create(capture) { _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }

        XCTAssertEqual(outcome, .uncertain(assetID: "created-asset"))
        XCTAssertEqual(library.requests.count, 1)
    }

    func testNativeFailureAfterIssuanceIsUncertainEvenWithoutPlaceholder() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let (staging, capture) = try await fixture.validatedForPhotos()
        for id in ["created-asset", nil] {
            let library = PhotoImportCreationSpy(assetID: id, success: false, error: CocoaError(.userCancelled))
            let outcome = await NativePhotoImportGateway(staging: staging, creation: library).create(capture) { _ in }
            XCTAssertEqual(outcome, .uncertain(assetID: id))
        }
    }

    func testSuccessfulCompletionWithoutPlaceholderIsUncertain() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let (staging, capture) = try await fixture.validatedForPhotos()
        let library = PhotoImportCreationSpy(assetID: nil)

        let outcome = await NativePhotoImportGateway(staging: staging, creation: library).create(capture) { _ in }

        XCTAssertEqual(outcome, .uncertain(assetID: nil))
    }

    func testCancellingCallerAfterIssuanceStillReceivesNativeSettlement() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let (staging, capture) = try await fixture.validatedForPhotos()
        let (issued, notice) = AsyncStream.makeStream(of: Void.self)
        let (completions, settlement) = AsyncStream.makeStream(of: (@Sendable (Bool, Error?) -> Void).self)
        let library = PhotoImportCreationSpy(settle: { completion in
            settlement.yield(completion)
            settlement.finish()
        })
        let gateway = NativePhotoImportGateway(staging: staging, creation: library)

        let running = Task {
            await gateway.create(capture) { _ in
                notice.yield(())
                notice.finish()
            }
        }

        var iterator = issued.makeAsyncIterator()
        let wasIssued: Void? = await iterator.next()
        XCTAssertNotNil(wasIssued)
        running.cancel()
        var completionIterator = completions.makeAsyncIterator()
        let completion = await completionIterator.next()
        try XCTUnwrap(completion)(true, nil)
        let outcome = await running.value
        XCTAssertEqual(outcome, .submitted(assetID: "created-asset"))
    }
}

private final class PhotoImportCreationSpy: PhotoImportCreationBackend, @unchecked Sendable {
    let access: LibraryAccess
    let isAvailable: Bool
    private let supported: Bool
    private let assetID: String?
    private let settle: @Sendable (@escaping @Sendable (Bool, Error?) -> Void) -> Void
    private let lock = NSLock()
    private var recordedRequests: [PhotoImportCreation] = []
    private var recordedTypes: [[PHAssetResourceType]] = []

    var requests: [PhotoImportCreation] { lock.withLock { recordedRequests } }
    var supportedTypes: [[PHAssetResourceType]] { lock.withLock { recordedTypes } }

    init(access: LibraryAccess = .full, available: Bool = true, supports: Bool = true, assetID: String? = "created-asset",
         success: Bool = true, error: Error? = nil,
         settle: (@Sendable (@escaping @Sendable (Bool, Error?) -> Void) -> Void)? = nil) {
        self.access = access
        isAvailable = available
        supported = supports
        self.assetID = assetID
        self.settle = settle ?? { $0(success, error) }
    }

    func supports(_ types: [PHAssetResourceType]) -> Bool {
        lock.withLock { recordedTypes.append(types) }
        return supported
    }

    func performCreation(_ request: PhotoImportCreation, onPlaceholder: @escaping @Sendable (String) -> Void,
                         completion: @escaping @Sendable (Bool, Error?) -> Void) {
        lock.withLock { recordedRequests.append(request) }
        if let assetID { onPlaceholder(assetID) }
        settle(completion)
    }
}

extension ImportFileFixture {
    func validatedForPhotos(pair: Bool = true) async throws -> (ImportStagingStore, ValidatedCapture) {
        let staging = try ImportStagingStore(root: root)
        var originals = [try await staging.write(object: object(.raf), session: ImportFileSession(bytes: raf))]
        if pair {
            originals.append(try await staging.write(object: object(), session: ImportFileSession(bytes: jpeg)))
        }
        let capture = try OriginalImportValidator(staging: staging).validate(
            selection(pair: pair), originals: originals, importDate: Date(timeIntervalSince1970: 1_700_000_000))
        return (staging, capture)
    }
}
