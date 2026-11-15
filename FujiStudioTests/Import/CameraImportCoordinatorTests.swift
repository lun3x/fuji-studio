import Foundation
import FujiCameraCore
import Synchronization
import XCTest
@testable import FujiStudio

@MainActor
final class CameraImportCoordinatorTests: XCTestCase {
    func testThreeFrozenCapturesDownloadAndSaveSequentially() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let selections = [harness.selection(1), harness.selection(2, pair: false), harness.selection(3)]
        let session = harness.session(selections)
        let jobID = try await harness.coordinator.start(selections, session: session)
        let event = await importEvent(harness.coordinator, jobID: jobID) { $0.receipts.count == 3 && !$0.isRunning }
        XCTAssertEqual(event?.receipts.map(\.captureID), selections.map(\.captureID))
        XCTAssertEqual(event?.retainedBytes, 0)
        XCTAssertEqual(harness.trace.values.withLock { $0 }, [
            "download:DSCF0001.RAF", "download:DSCF0001.JPG", "create:DSCF0001.RAF",
            "download:DSCF0002.RAF", "create:DSCF0002.RAF",
            "download:DSCF0003.RAF", "download:DSCF0003.JPG", "create:DSCF0003.RAF"
        ])
        let job = try await harness.job(jobID)
        XCTAssertEqual(job.captures.map(\.stage), [.imported, .imported, .imported])
        XCTAssertTrue(job.captures.allSatisfy { $0.originals.isEmpty })
        let submitted = await harness.photos.observedSubmittingIntent
        XCTAssertEqual(submitted, [true, true, true])
    }

    func testDisconnectDuringEitherComponentRestartsPartialAndRematchesFreshHandles() async throws {
        for failingFormat in [WirelessObjectFormat.raf, .jpeg] {
            let harness = try CameraImportHarness()
            defer { harness.fixture.cleanUp() }
            let selection = harness.selection(1)
            let interrupted = harness.session([selection], interrupt: failingFormat)
            let jobID = try await harness.coordinator.start([selection], session: interrupted)
            let paused = await importEvent(harness.coordinator, jobID: jobID) { $0.pauseReason == .connectionLost && !$0.isRunning }
            XCTAssertEqual(paused?.actions.contains(.resume), true)
            XCTAssertEqual(paused?.actions.contains(.skipCapture), true)
            XCTAssertFalse(try harness.stagedFiles().contains { $0.pathExtension == "part" })
            let before = try await harness.job(jobID)
            let retained = failingFormat == .jpeg ? [ImportOriginalRole.raf] : []
            XCTAssertEqual(before.captures[0].originals.map(\.role), retained)
            let newSelection = harness.selection(1, sessionID: UUID(), handleOffset: 100)
            let fresh = harness.session([newSelection])
            try await harness.coordinator.resume(jobID: jobID, session: fresh)
            _ = await importEvent(harness.coordinator, jobID: jobID) { $0.receipts.count == 1 && !$0.isRunning }
            let observedHandles = await fresh.handles
            // A reconnect rechecks a retained RAW over WiFi but keeps its existing staged URL.
            XCTAssertEqual(observedHandles, [102, 103])
            let usedPaths = await harness.photos.submittedPaths
            if let raw = before.captures[0].originals.first {
                XCTAssertEqual(usedPaths.first?.first, raw.relativePath)
            }
        }
    }

    func testChangedPairMateRequiresFreshSelectionAndNeverSubmitsRawAlone() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let selection = harness.selection(1)
        let jobID = try await harness.coordinator.start([selection], session: harness.session([selection], interrupt: .jpeg))
        _ = await importEvent(harness.coordinator, jobID: jobID) { $0.pauseReason == .connectionLost && !$0.isRunning }

        let replacement = harness.selection(1, pair: false, sessionID: UUID(), handleOffset: 100)
        try await harness.coordinator.resume(jobID: jobID, session: harness.session([replacement]))
        let event = await importEvent(harness.coordinator, jobID: jobID) { $0.pauseReason == .freshSelectionRequired && !$0.isRunning }
        XCTAssertEqual(event?.actions.contains(.retryCapture), false)
        let submitted = await harness.photos.submittedPaths
        XCTAssertTrue(submitted.isEmpty)
        let job = try await harness.job(jobID)
        XCTAssertEqual(job.captures[0].selection.policy, .pair)
        XCTAssertEqual(job.captures[0].originals.map(\.role), [.raf])
        await harness.coordinator.pause(jobID: jobID, reason: .backgrounded)
        let stillNeedsSelection = try await harness.job(jobID)
        XCTAssertEqual(stillNeedsSelection.pauseReason, .freshSelectionRequired)
        let sameMetadata = harness.selection(1, sessionID: UUID(), handleOffset: 200)
        await assertImportThrows {
            try await harness.coordinator.resume(jobID: jobID, session: harness.session([sameMetadata]))
        }
    }

    func testReconnectRejectsReusedMetadataWhenRetainedRawBytesDiffer() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let selection = harness.selection(1)
        let jobID = try await harness.coordinator.start([selection], session: harness.session([selection], interrupt: .jpeg))
        _ = await importEvent(harness.coordinator, jobID: jobID) { $0.pauseReason == .connectionLost && !$0.isRunning }
        let replacement = harness.selection(1, sessionID: UUID(), handleOffset: 100)
        let fresh = harness.session([replacement], changedRAW: true)
        try await harness.coordinator.resume(jobID: jobID, session: fresh)
        _ = await importEvent(harness.coordinator, jobID: jobID) { $0.pauseReason == .freshSelectionRequired && !$0.isRunning }
        let submitted = await harness.photos.submittedPaths
        let handles = await fresh.handles
        XCTAssertTrue(submitted.isEmpty)
        XCTAssertEqual(handles, [102])
    }

    func testDiskFullPausesWithActionsAndSkipContinuesFrozenQueue() async throws {
        let fail = Mutex(true)
        let harness = try CameraImportHarness(beforeChunkWrite: {
            if fail.withLock({ $0 }) { throw POSIXError(.ENOSPC) }
        })
        defer { harness.fixture.cleanUp() }
        let selections = [harness.selection(1), harness.selection(2)]
        let failedSession = harness.session(selections)
        let jobID = try await harness.coordinator.start(selections, session: failedSession)
        let paused = await importEvent(harness.coordinator, jobID: jobID) { $0.pauseReason == .storage && !$0.isRunning }
        XCTAssertEqual(paused?.actions.isSuperset(of: [.retryCapture, .skipCapture, .cancelRemaining]), true)
        XCTAssertEqual(paused?.needsSession, true)
        XCTAssertEqual(paused?.invalidatedSession, true)
        XCTAssertTrue(try harness.stagedFiles().isEmpty)
        await harness.coordinator.reconcile()
        let admitted = await harness.coordinator.latestRunEvent(jobID: jobID)
        XCTAssertEqual(admitted?.runID, paused?.runID)
        XCTAssertNotNil(admitted?.runID)
        XCTAssertEqual(admitted?.invalidatedSession, true)

        fail.withLock { $0 = false }
        try await harness.coordinator.skipCapture(jobID: jobID)
        let skipped = try await harness.job(jobID)
        XCTAssertEqual(skipped.captures.map(\.stage), [.skipped, .queued])
        let handles = await failedSession.handles
        XCTAssertEqual(handles, [2])
        let fresh = harness.session([harness.selection(2, sessionID: UUID(), handleOffset: 100)])
        try await harness.coordinator.resume(jobID: jobID, session: fresh)
        let finished = await importEvent(harness.coordinator, jobID: jobID) { $0.receipts.count == 1 && !$0.isRunning }
        XCTAssertEqual(finished?.receipts.first?.captureID, selections[1].captureID)
        XCTAssertNotEqual(finished?.runID, admitted?.runID)
        let job = try await harness.job(jobID)
        XCTAssertEqual(job.captures.map(\.stage), [.skipped, .imported])
    }

    func testForegroundReconcileDefersCleanupUntilActivePartialCloses() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let selection = harness.selection(1)
        let gate = ImportTestGate()
        let session = harness.session([selection], hold: (selection.descriptors[0].handle, gate))
        let jobID = try await harness.coordinator.start([selection], session: session)
        await gate.waitUntilEntered()
        await harness.coordinator.reconcile()
        XCTAssertEqual(try harness.stagedFiles().map(\.pathExtension), ["part"])
        let pending = try await harness.job(jobID)
        XCTAssertEqual(pending.captures[0].stage, .downloading)
        await gate.release()
        _ = await importEvent(harness.coordinator, jobID: jobID) { $0.receipts.count == 1 && !$0.isRunning }
    }

    func testCancelWhileDownloadingDropsPartialAndPreservesEarlierReceipt() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let selections = [harness.selection(1, pair: false), harness.selection(2), harness.selection(3)]
        let gate = ImportTestGate()
        let session = harness.session(selections, hold: (selections[1].descriptors[1].handle, gate))
        let jobID = try await harness.coordinator.start(selections, session: session)
        await gate.waitUntilEntered()
        let cancellation = Task { await harness.coordinator.cancelRemaining(jobID: jobID) }
        _ = await importEvent(harness.coordinator, jobID: jobID) { $0.pauseReason == .cancelled }
        await gate.release()
        await cancellation.value
        let paused = await importEvent(harness.coordinator, jobID: jobID) { $0.pauseReason == .cancelled && !$0.isRunning }
        XCTAssertEqual(paused?.receipts.map(\.captureID), [selections[0].captureID])
        XCTAssertEqual(paused?.retainedBytes, UInt64(harness.fixture.raf.count))
        XCTAssertEqual(try harness.stagedFiles().map(\.pathExtension), ["raf"])
        let handles = await session.handles
        XCTAssertEqual(handles, [2, 4, 5])
        try await harness.coordinator.discardRemaining(jobID: jobID)
        XCTAssertTrue(try harness.stagedFiles().isEmpty)
        let discarded = try await harness.job(jobID)
        XCTAssertEqual(discarded.captures.map(\.stage), [.imported, .skipped, .skipped])
    }

    func testCancelWaitsForAlreadySubmittedSaveAndAcceptsVerifiedResult() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let gate = ImportTestGate()
        await harness.photos.holdNextCreate(at: gate)
        let selections = [harness.selection(1), harness.selection(2)]
        let jobID = try await harness.coordinator.start(selections, session: harness.session(selections))
        await gate.waitUntilEntered()
        let cancel = Task { await harness.coordinator.cancelRemaining(jobID: jobID) }
        _ = await importEvent(harness.coordinator, jobID: jobID) { $0.pauseReason == .cancelled }
        let pending = try await harness.job(jobID)
        XCTAssertEqual(pending.captures.map(\.stage), [.submitting, .queued])
        XCTAssertEqual(pending.captures[0].originals.count, 2)
        await gate.release()
        await cancel.value
        let result = try await harness.job(jobID)
        XCTAssertEqual(result.captures.map(\.stage), [.imported, .queued])
        XCTAssertEqual(result.pauseReason, .cancelled)
        XCTAssertTrue(try harness.stagedFiles().isEmpty)
    }
}

@MainActor
func importEvent(_ coordinator: CameraImportCoordinator, jobID: UUID?,
                 matching: @escaping @Sendable (ImportEvent) -> Bool,
                 file: StaticString = #filePath, line: UInt = #line) async -> ImportEvent? {
    var result: ImportEvent?
    let received = XCTestExpectation(description: "import event for \(String(describing: jobID))")
    let consumer = Task {
        for await event in await coordinator.events() where event.jobID == jobID && matching(event) {
            result = event
            received.fulfill()
            break
        }
    }
    _ = await XCTWaiter.fulfillment(of: [received], timeout: 5)
    consumer.cancel()
    await consumer.value
    if result == nil { XCTFail("Timed out waiting for matching import event", file: file, line: line) }
    return result
}

final class ImportTestTrace: Sendable {
    let values = Mutex<[String]>([])
}

struct CameraImportHarness {
    let fixture: ImportFileFixture
    let journal: ImportJournal
    let staging: ImportStagingStore
    let photos: ImportTestPhotos
    let coordinator: CameraImportCoordinator
    let trace = ImportTestTrace()

    init(beforeChunkWrite: @escaping @Sendable () throws -> Void = {},
         beforeJournalReplace: @escaping @Sendable () throws -> Void = {},
         beforeJournalDirectorySync: @escaping @Sendable () throws -> Void = {}) throws {
        fixture = try ImportFileFixture()
        journal = try ImportJournal(root: fixture.root.appendingPathComponent("journal"),
            beforeReplace: beforeJournalReplace, beforeDirectorySync: beforeJournalDirectorySync)
        staging = try ImportStagingStore(root: fixture.root.appendingPathComponent("staging"), beforeChunkWrite: beforeChunkWrite)
        photos = .init(journal: journal, trace: trace)
        coordinator = .init(journal: journal, staging: staging, gateway: photos)
    }

    func selection(_ number: Int, pair: Bool = true, sessionID: UUID? = nil, handleOffset: UInt32 = 0,
                   camera: WirelessIdentity? = nil) -> ImportSelection {
        let camera = camera ?? fixture.camera
        let formats: [WirelessObjectFormat] = pair ? [.raf, .jpeg] : [.raf]
        let descriptors = formats.enumerated().map { index, format in
            let original = fixture.object(format)
            let ext = format == .raf ? "RAF" : "JPG"
            return WirelessObjectDescriptor(cameraID: camera.cameraID, sessionID: sessionID ?? fixture.sessionID,
                storageID: 1, handle: handleOffset + UInt32(number * 2 + index), directory: original.directory,
                filename: String(format: "DSCF%04d.%@", number, ext), format: format,
                byteLength: original.byteLength, captureDate: original.captureDate,
                dimensions: original.dimensions, orientation: original.orientation)
        }
        return .init(captureID: .init(describing: descriptors), camera: camera, descriptors: descriptors,
                     policy: pair ? .pair : .rawOnly)
    }

    func session(_ selections: [ImportSelection], interrupt: WirelessObjectFormat? = nil, changedRAW: Bool = false,
                 hold: (UInt32, ImportTestGate)? = nil) -> ImportTestSession {
        var raw = fixture.raf
        if changedRAW { raw[raw.count - 1] ^= 0xff }
        return .init(camera: selections[0].camera, objects: selections.flatMap(\.descriptors),
                     bytes: [.raf: raw, .jpeg: fixture.jpeg], interrupt: interrupt, trace: trace, hold: hold)
    }

    func job(_ id: UUID) async throws -> ImportJob {
        let jobs = try await journal.loadJobs()
        return try XCTUnwrap(jobs.first { $0.id == id })
    }

    func stagedFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: fixture.root.appendingPathComponent("staging"),
                                                  includingPropertiesForKeys: nil)
    }

    func reopened() throws -> CameraImportCoordinator {
        let reopened = try ImportJournal(root: fixture.root.appendingPathComponent("journal"))
        return .init(journal: reopened, staging: staging, gateway: photos)
    }
}

actor ImportTestSession: WirelessTransferSession {
    let camera: WirelessIdentity
    let objects: [WirelessObjectDescriptor]
    let bytes: [WirelessObjectFormat: Data]
    let interrupt: WirelessObjectFormat?
    let trace: ImportTestTrace
    let hold: (UInt32, ImportTestGate)?
    private(set) var handles: [UInt32] = []
    private(set) var openCount = 0

    init(camera: WirelessIdentity, objects: [WirelessObjectDescriptor], bytes: [WirelessObjectFormat: Data],
         interrupt: WirelessObjectFormat?, trace: ImportTestTrace, hold: (UInt32, ImportTestGate)?) {
        self.camera = camera
        self.objects = objects
        self.bytes = bytes
        self.interrupt = interrupt
        self.hold = hold
        self.trace = trace
    }

    func open() async throws -> WirelessIdentity { openCount += 1; return camera }
    func capabilities() async throws -> WirelessCapabilities {
        .init(mode: .xApp, rawExposure: .available, storageIDs: [1], originalSizeVerified: true, evidenceID: "test")
    }
    func enumerate() async throws -> AsyncThrowingStream<WirelessInventoryBatch, Error> {
        .init { stream in
            stream.yield(.init(objects: objects, storageChanges: [1: .complete], rawExposure: .available))
            stream.finish()
        }
    }
    func thumbnail(_ object: WirelessObjectDescriptor) async throws -> Data { throw WirelessFailure.unsupportedProtocol }
    func download(_ object: WirelessObjectDescriptor, to sink: @escaping @Sendable (Data) async throws -> Void) async throws {
        guard objects.contains(object), let data = bytes[object.format] else { throw WirelessFailure.objectChanged }
        handles.append(object.handle)
        trace.values.withLock { $0.append("download:" + object.filename) }
        let half = data.count / 2
        try await sink(Data(data.prefix(half)))
        if let hold, hold.0 == object.handle { await hold.1.enter() }
        if interrupt == object.format { throw WirelessFailure.connectionLost }
        try await sink(Data(data.dropFirst(half)))
    }
    func close() async throws {}
}

actor ImportTestPhotos: PhotoImportGateway {
    private let journal: ImportJournal
    private let trace: ImportTestTrace
    private var assets: [String: ImportedAssetInspection] = [:]
    private var search: ImportCandidateSearch = .narrow([])
    private var searchGate: ImportTestGate?
    private var nextOutcome: PhotoImportOutcome?
    private var createGate: ImportTestGate?
    private(set) var observedSubmittingIntent: [Bool] = []
    private(set) var submittedPaths: [[String]] = []

    init(journal: ImportJournal, trace: ImportTestTrace) {
        self.journal = journal
        self.trace = trace
    }

    func holdNextCreate(at gate: ImportTestGate) { createGate = gate }
    func holdNextSearch(at gate: ImportTestGate) { searchGate = gate }
    func setInspection(_ inspection: ImportedAssetInspection, for id: String) { assets[id] = inspection }
    func setSearch(_ result: ImportCandidateSearch) { search = result }
    func setNextOutcome(_ outcome: PhotoImportOutcome) { nextOutcome = outcome }

    func create(_ capture: ValidatedCapture,
                onPlaceholder: @escaping @Sendable (String) throws -> Void) async -> PhotoImportOutcome {
        let jobs = (try? await journal.loadJobs()) ?? []
        observedSubmittingIntent.append(jobs.contains { job in
            job.captures.contains { $0.id == capture.selection.captureID && $0.stage == .submitting
                && $0.originals == capture.originals }
        })
        submittedPaths.append(capture.originals.map(\.relativePath))
        trace.values.withLock { $0.append("create:" + capture.originals[0].originalFilename) }
        if let outcome = nextOutcome {
            nextOutcome = nil
            if case .uncertain(let id?) = outcome { try? onPlaceholder(id) }
            return outcome
        }
        let id = "asset-\(submittedPaths.count)"
        do { try onPlaceholder(id) } catch { return .uncertain(assetID: id) }
        if let gate = createGate {
            createGate = nil
            await gate.enter()
        }
        let resources = capture.originals.map { original in
            ImportedResourceFingerprint(role: capture.originals.count == 2 && original.role == .raf ? .alternate : .primary,
                format: original.role, originalFilename: original.originalFilename, byteCount: original.byteCount,
                sha256: original.sha256)
        }
        assets[id] = .found(.init(assetID: id, originals: resources))
        return .submitted(assetID: id)
    }

    func inspect(assetID: String) async throws -> ImportedAssetInspection { assets[assetID] ?? .unavailable }
    func candidates(for capture: ValidatedCapture) async throws -> [String] { search.assetIDs }
    func candidateSearch(for capture: ValidatedCapture) async throws -> ImportCandidateSearch {
        if let gate = searchGate {
            searchGate = nil
            await gate.enter()
        }
        return search
    }
}

actor ImportTestGate {
    private var released = false
    private var entered = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enter() async {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
