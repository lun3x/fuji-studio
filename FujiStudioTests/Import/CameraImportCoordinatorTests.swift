import Foundation
import FujiCameraCore
import Synchronization
import XCTest
@testable import FujiStudio

@MainActor
final class CameraImportCoordinatorTests: XCTestCase {
    func testViewerAndSaveShareOriginalsAndFetchOnlyMissingComponents() async throws {
        for viewRAW in [false, true] {
            let harness = try CameraImportHarness()
            defer { harness.fixture.cleanUp() }
            let pair = harness.selection(1)
            let rawOnly = harness.selection(2, pair: false)
            let session = harness.session([pair, rawOnly])
            let cache = harness.coordinator.originalCache
            let browser = CameraBrowserModel(originalCache: cache)
            await browser.load(session: session)
            let raw = pair.descriptors[0], jpeg = pair.descriptors[1]
            browser.apply(.sourceTapped(raw.trayID))
            XCTAssertEqual(browser.viewerRequest?.original, jpeg)
            let first = try await browser.viewerFile(for: jpeg)
            browser.apply(.sourceTapped(rawOnly.descriptors[0].trayID))
            XCTAssertNil(browser.viewerRequest?.original)
            browser.apply(.sourceTapped(raw.trayID))
            let reopened = try await browser.viewerFile(for: jpeg)
            XCTAssertEqual(first.lease, reopened.lease)
            if viewRAW {
                browser.apply(.versionSelected(.raw))
                XCTAssertEqual(browser.viewerRequest?.original, raw)
                // The tiny test RAF has valid import metadata but no renderable sensor plane.
                _ = try await cache.viewerOriginal(raw, session: session)
            }
            let opened = await session.handles
            XCTAssertEqual(opened, viewRAW ? [jpeg.handle, raw.handle] : [jpeg.handle])

            let jobID = try await harness.coordinator.start([pair], session: session, matchedInBrowser: true)
            let result = await importEvent(harness.coordinator, jobID: jobID) { !$0.isRunning && !$0.receipts.isEmpty }
            XCTAssertEqual(result?.receipts.count, 1)
            let scans = await session.enumerations
            XCTAssertEqual(scans, 1)
            let afterSave = await session.handles
            XCTAssertEqual(afterSave, [jpeg.handle, raw.handle])

            let disk = CameraOriginalCache(root: harness.staging.cameraCacheDirectory)
            for object in pair.descriptors {
                let entry = try await disk.viewerOriginal(object, session: session)
                XCTAssertEqual(try Data(contentsOf: entry.url), object.format == .raf ? harness.fixture.raf : harness.fixture.jpeg)
            }
            let revisited = await session.handles
            XCTAssertEqual(revisited, afterSave)
        }
    }

    func testCacheReopensAcrossSessionsAndRejectsChangedCardBytes() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let first = harness.selection(1)
        let cached = try await harness.coordinator.originalCache.viewerOriginal(first.descriptors[0], session: harness.session([first]))
        let disk = CameraOriginalCache(root: harness.staging.cameraCacheDirectory)
        let next = harness.selection(1, sessionID: UUID(), handleOffset: 100)
        let matching = harness.session([next])
        let hit = try await disk.viewerOriginal(next.descriptors[0], session: matching)
        XCTAssertEqual(cached.url, hit.url)
        let reused = await matching.handles
        XCTAssertTrue(reused.isEmpty)

        let replacement = harness.selection(1, sessionID: UUID(), handleOffset: 200)
        let changed = harness.session([replacement], changedRAW: true)
        let miss = try await disk.viewerOriginal(replacement.descriptors[0], session: changed)
        let requests = await changed.handles
        XCTAssertEqual(requests, [replacement.descriptors[0].handle])
        XCTAssertNotEqual(miss.original.sha256, hit.original.sha256)
    }

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

    func testLateRetirementLeavesReplacementLoanAvailableForAuthorizedRetry() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let initial = [harness.selection(1), harness.selection(2)]
        let oldLoan = UUID(), replacementLoan = UUID()
        await harness.photos.setNextOutcome(.rejected(.authorization))
        let jobID = try await harness.coordinator.start(initial, session: harness.session(initial), loanID: oldLoan)
        let paused = await importEvent(harness.coordinator, jobID: jobID) { $0.pauseReason == .photosAccess && !$0.isRunning }
        XCTAssertEqual(paused?.needsSession, false)
        await harness.coordinator.retireLoan(oldLoan, reason: .connectionLost)

        let sessionID = UUID()
        let fresh = [harness.selection(1, sessionID: sessionID, handleOffset: 100),
                     harness.selection(2, sessionID: sessionID, handleOffset: 100)]
        let replacement = harness.session(fresh)
        await harness.photos.setNextOutcome(.rejected(.authorization))
        try await harness.coordinator.resume(jobID: jobID, session: replacement, loanID: replacementLoan)
        _ = await importEvent(harness.coordinator, jobID: jobID) {
            $0.runID != paused?.runID && $0.pauseReason == .photosAccess && !$0.isRunning
        }
        let retired = await harness.coordinator.retireLoan(oldLoan, reason: .connectionLost)
        XCTAssertNil(retired)
        let current = await harness.coordinator.latestEvent(jobID: jobID)
        XCTAssertEqual(current?.needsSession, false)
        try await harness.coordinator.retryCapture(jobID: jobID, usingLoanID: replacementLoan)
        let finished = await importEvent(harness.coordinator, jobID: jobID) { $0.receipts.count == 2 && !$0.isRunning }
        XCTAssertEqual(finished?.receipts.count, 2)
        let downloadedHandles = await replacement.handles
        XCTAssertEqual(downloadedHandles, [102, 103, 104, 105])
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
        try await harness.coordinator.skipCapture(jobID: jobID, usingLoanID: nil)
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

    func testResumeReservesPhotosCopyForRetainedRawBeforeDownloadingJPEG() async throws {
        let availableBytes = Mutex(UInt64.max)
        let harness = try CameraImportHarness(availableCapacity: { availableBytes.withLock { $0 } })
        defer { harness.fixture.cleanUp() }
        let selection = harness.selection(1)
        let jobID = try await harness.coordinator.start(
            [selection], session: harness.session([selection], interrupt: .jpeg))
        _ = await importEvent(harness.coordinator, jobID: jobID) { $0.pauseReason == .connectionLost && !$0.isRunning }
        availableBytes.withLock { $0 = 64 * 1024 * 1024 + 2 * UInt64(harness.fixture.jpeg.count) }

        let current = harness.selection(1, sessionID: UUID(), handleOffset: 100)
        let fresh = harness.session([current])
        try await harness.coordinator.resume(jobID: jobID, session: fresh)
        let paused = await importEvent(harness.coordinator, jobID: jobID) { !$0.isRunning }
        XCTAssertEqual(paused?.pauseReason, .storage)
        let downloads = await fresh.handles
        let creates = await harness.photos.submittedPaths.count
        XCTAssertTrue(downloads.isEmpty)
        XCTAssertEqual(creates, 0)
        XCTAssertEqual(try harness.stagedFiles().map(\.pathExtension), ["raf"])
    }

    func testCapacityDropAfterPreflightBlocksPhotosWithBothFilesStaged() async throws {
        let checkedCapacity = Mutex(false)
        let harness = try CameraImportHarness(availableCapacity: {
            checkedCapacity.withLock {
                defer { $0 = true }
                return $0 ? 64 * 1024 * 1024 : UInt64.max
            }
        })
        defer { harness.fixture.cleanUp() }
        let selection = harness.selection(1)
        let jobID = try await harness.coordinator.start([selection], session: harness.session([selection]))
        let paused = await importEvent(harness.coordinator, jobID: jobID) { !$0.isRunning }
        XCTAssertEqual(paused?.pauseReason, .storage)
        XCTAssertEqual(paused?.stage, .readyToSave)
        let creates = await harness.photos.submittedPaths.count
        XCTAssertEqual(creates, 0)
        XCTAssertEqual(try harness.stagedFiles().count, 2)
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

    func testUnresolvedSaveBlocksAlternatePolicyForTheSameVerifiedRAW() async throws {
        for initialPair in [true, false] {
            for changedRAW in [false, true] {
                let harness = try CameraImportHarness()
                defer { harness.fixture.cleanUp() }
                let initial = harness.selection(1, pair: initialPair)
                await harness.photos.setNextOutcome(.uncertain(assetID: "possible-save"))
                let oldLoan = UUID()
                let pendingID = try await harness.coordinator.start(
                    [initial], session: harness.session([initial]), loanID: oldLoan)
                let pending = await importEvent(harness.coordinator, jobID: pendingID) { !$0.isRunning }
                XCTAssertEqual(pending?.pauseReason, .unresolvedSave)
                await harness.coordinator.retireLoan(oldLoan, reason: .connectionLost)

                let alternate = harness.selection(1, pair: !initialPair, sessionID: UUID(), handleOffset: 100)
                let session = harness.session([alternate], changedRAW: changedRAW)
                let alternateID = try await harness.coordinator.start([alternate], session: session)
                let settled = await importEvent(harness.coordinator, jobID: alternateID) { !$0.isRunning }
                let handles = await session.handles
                let creates = await harness.photos.submittedPaths.count
                let preserved = try await harness.job(pendingID)
                let missing = alternate.descriptors.filter { changedRAW || $0.format == .jpeg }
                XCTAssertEqual(handles, missing.map(\.handle))
                XCTAssertEqual(creates, changedRAW ? 2 : 1)
                XCTAssertEqual(settled?.receipts.count, changedRAW ? 1 : 0)
                XCTAssertEqual(settled?.pauseReason, changedRAW ? nil : .earlierSaveUnresolved)
                XCTAssertTrue(preserved.captures[0].stage.mayHaveSubmitted)
                XCTAssertEqual(preserved.captures[0].originals.count, initial.descriptors.count)
                if !changedRAW {
                    let verifiedEarlierResources = preserved.captures[0].originals.map { original in
                        ImportedResourceFingerprint(role: initialPair && original.role == .raf ? .alternate : .primary,
                            format: original.role, originalFilename: original.originalFilename,
                            byteCount: original.byteCount, sha256: original.sha256)
                    }
                    await harness.photos.setInspection(
                        .found(.init(assetID: "possible-save", originals: verifiedEarlierResources)), for: "possible-save")
                    await harness.coordinator.reconcile()
                    let verified = try await harness.job(pendingID)
                    XCTAssertEqual(verified.captures[0].receipt?.assetID, "possible-save")

                    try await harness.coordinator.retryCapture(jobID: alternateID, usingLoanID: nil)
                    let retried = await importEvent(harness.coordinator, jobID: alternateID) {
                        !$0.isRunning && $0.runID != settled?.runID
                    }
                    let submissions = await harness.photos.submittedPaths.count
                    XCTAssertEqual(submissions, 2)
                    XCTAssertEqual(retried?.receipts.first?.assetID, "asset-2")
                }
            }
        }
    }

    func testUnresolvedPairStillAllowsReuseOfAnExactVerifiedRAWOnlyReceipt() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }

        let original = harness.selection(1, pair: false)
        let originalID = try await harness.coordinator.start([original], session: harness.session([original]))
        let imported = await importEvent(harness.coordinator, jobID: originalID) { !$0.isRunning }
        XCTAssertEqual(imported?.receipts.first?.assetID, "asset-1")

        let pair = harness.selection(1, sessionID: UUID(), handleOffset: 100)
        let loan = UUID()
        await harness.photos.setNextOutcome(.uncertain(assetID: "uncertain-pair"))
        let pendingID = try await harness.coordinator.start([pair], session: harness.session([pair]), loanID: loan)
        let pending = await importEvent(harness.coordinator, jobID: pendingID) { !$0.isRunning }
        XCTAssertEqual(pending?.pauseReason, .unresolvedSave)
        await harness.coordinator.retireLoan(loan, reason: .connectionLost)

        let repeated = harness.selection(1, pair: false, sessionID: UUID(), handleOffset: 200)
        let repeatedID = try await harness.coordinator.start([repeated], session: harness.session([repeated]))
        let reused = await importEvent(harness.coordinator, jobID: repeatedID) { !$0.isRunning }
        XCTAssertEqual(reused?.receipts.first?.assetID, "asset-1")
        let submissions = await harness.photos.submittedPaths.count
        XCTAssertEqual(submissions, 2)
        let retained = try await harness.job(pendingID)
        XCTAssertTrue(retained.captures[0].stage.mayHaveSubmitted)
        XCTAssertEqual(retained.captures[0].originals.count, 2)
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
         beforeJournalDirectorySync: @escaping @Sendable () throws -> Void = {},
         availableCapacity: (@Sendable () throws -> UInt64?)? = nil) throws {
        fixture = try ImportFileFixture()
        journal = try ImportJournal(root: fixture.root.appendingPathComponent("journal"),
            beforeReplace: beforeJournalReplace, beforeDirectorySync: beforeJournalDirectorySync)
        staging = try ImportStagingStore(root: fixture.root.appendingPathComponent("staging"),
            beforeChunkWrite: beforeChunkWrite, availableCapacity: availableCapacity)
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

actor ImportTestSession: WirelessOriginalSampling {
    let camera: WirelessIdentity
    let objects: [WirelessObjectDescriptor]
    let bytes: [WirelessObjectFormat: Data]
    let interrupt: WirelessObjectFormat?
    let trace: ImportTestTrace
    let hold: (UInt32, ImportTestGate)?
    private(set) var handles: [UInt32] = []
    private(set) var openCount = 0
    private(set) var enumerations = 0

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
        enumerations += 1
        return .init { stream in
            stream.yield(.init(objects: objects, storageChanges: [1: .complete], rawExposure: .available))
            stream.finish()
        }
    }
    func originalSample(_ object: WirelessObjectDescriptor, offset: UInt32, count: UInt32) async throws -> Data {
        guard objects.contains(object), let data = bytes[object.format],
              Int(offset) + Int(count) <= data.count else { throw WirelessFailure.objectChanged }
        return data.subdata(in: Int(offset)..<Int(offset + count))
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
