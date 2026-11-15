import Foundation
import FujiCameraCore
import Synchronization
import XCTest
@testable import FujiStudio

@MainActor
final class ImportRecoveryTests: XCTestCase {
    func testRelaunchWithUncertainSaveNeverResubmits() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let selection = harness.selection(1)
        let job = try await seed(.submitting, with: harness, selection: selection)
        try harness.journal.placeholderWriter.persistPlaceholder(
            jobID: job.id, captureID: selection.captureID, assetID: "limited-asset")

        let reopened = try harness.reopened()
        await reopened.reconcile()
        let paused = await importEvent(reopened, jobID: job.id) { !$0.isRunning }
        XCTAssertEqual(paused?.pauseReason, .unresolvedSave)
        XCTAssertEqual(paused?.actions.contains(.resume), false)
        XCTAssertEqual(paused?.actions.contains(.discardRemaining), false)
        let session = harness.session([selection])
        await assertImportThrows { try await reopened.resume(jobID: job.id, session: session) }
        await assertImportThrows { try await reopened.retryCapture(jobID: job.id) }
        do {
            try await reopened.discardRemaining(jobID: job.id)
            XCTFail("Discard removed evidence of a possible Photos save")
        } catch {
            XCTAssertEqual(error as? CameraImportError, .unresolvedSave(retainedBytes: job.captures[0].originals
                .reduce(0) { $0 + $1.byteCount }))
        }
        let creates = await harness.photos.submittedPaths.count
        let opened = await session.openCount
        XCTAssertEqual(creates, 0)
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(try harness.stagedFiles().count, 2)
    }

    func testReconcileCanRecoverLostCallbackUsingCompletePhotosFingerprint() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let selection = harness.selection(1)
        let job = try await seed(.submitting, with: harness, selection: selection)
        let snapshot = snapshot("found-without-callback", originals: job.captures[0].originals)
        await harness.photos.setInspection(.found(snapshot), for: snapshot.assetID)
        await harness.photos.setSearch(.narrow([snapshot.assetID]))
        let reopened = try harness.reopened()
        await reopened.reconcile()
        let committed = try await harness.job(job.id)
        XCTAssertEqual(committed.captures[0].stage, .imported)
        XCTAssertEqual(committed.captures[0].receipt?.assetID, snapshot.assetID)
        XCTAssertTrue(try harness.stagedFiles().isEmpty)
        let creates = await harness.photos.submittedPaths.count
        XCTAssertEqual(creates, 0)
    }

    func testLocatedUnreadablePlaceholderRemainsOwnedAndPinned() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let selection = harness.selection(1)
        let job = try await seed(.submitting, with: harness, selection: selection)
        try harness.journal.placeholderWriter.persistPlaceholder(jobID: job.id, captureID: selection.captureID, assetID: "known")
        let older = snapshot("older-identical", originals: job.captures[0].originals)
        await harness.photos.setInspection(.found(older), for: older.assetID)
        await harness.photos.setInspection(.foundUnreadable, for: "known")
        await harness.photos.setSearch(.authoritative([older.assetID]))
        await harness.coordinator.reconcile()
        let unresolved = try await harness.job(job.id)
        XCTAssertEqual(unresolved.captures[0].placeholderAssetID, "known")
        XCTAssertEqual(unresolved.captures[0].stage, .savedUnverified)
        XCTAssertNil(unresolved.captures[0].receipt)
        XCTAssertEqual(try harness.stagedFiles().count, 2)
    }

    func testAuthoritativeAbsenceRequiresExplicitRetryAndDoesNotReusePlaceholder() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let selection = harness.selection(1)
        let job = try await seed(.submitting, with: harness, selection: selection)
        try harness.journal.placeholderWriter.persistPlaceholder(jobID: job.id, captureID: selection.captureID, assetID: "old")
        await harness.photos.setInspection(.absent, for: "old")
        await harness.photos.setSearch(.authoritative([]))
        let reopened = try harness.reopened()
        await reopened.reconcile()
        let pending = try await harness.job(job.id)
        XCTAssertEqual(pending.captures[0].placeholderAssetID, "old")
        XCTAssertTrue(pending.captures[0].stage.mayHaveSubmitted)
        let priorCreates = await harness.photos.submittedPaths.count
        XCTAssertEqual(priorCreates, 0)
        let eligible = await importEvent(reopened, jobID: job.id) { !$0.isRunning }
        XCTAssertEqual(eligible?.actions.contains(.retryCapture), true)
        try await reopened.retryCapture(jobID: job.id)
        _ = await importEvent(reopened, jobID: job.id) { $0.receipts.count == 1 && !$0.isRunning }
        let finished = try await harness.job(job.id)
        XCTAssertEqual(finished.captures[0].receipt?.assetID, "asset-1")
        XCTAssertEqual(finished.captures[0].placeholderAssetID, "asset-1")
    }

    func testDefinitiveRejectionPermitsLocalRetryAfterRelaunch() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let selection = harness.selection(1)
        await harness.photos.setNextOutcome(.rejected(.authorization))
        let jobID = try await harness.coordinator.start([selection], session: harness.session([selection]))
        _ = await importEvent(harness.coordinator, jobID: jobID) { $0.pauseReason == .photosAccess && !$0.isRunning }
        let rejected = try await harness.job(jobID)
        XCTAssertEqual(rejected.captures[0].stage, .readyToSave)
        XCTAssertEqual(try harness.stagedFiles().count, 2)
        let reopened = try harness.reopened()
        await reopened.reconcile()
        try await reopened.retryCapture(jobID: jobID)
        _ = await importEvent(reopened, jobID: jobID) { $0.receipts.count == 1 && !$0.isRunning }
        let submitted = await harness.photos.submittedPaths
        XCTAssertEqual(submitted, Array(repeating: rejected.captures[0].originals.map(\.relativePath), count: 2))
    }

    func testStaleAbsenceCannotClearNewlyRecordedPlaceholder() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let selection = harness.selection(1)
        let job = try await seed(.submitting, with: harness, selection: selection)
        try harness.journal.placeholderWriter.persistPlaceholder(
            jobID: job.id, captureID: selection.captureID, assetID: "new-identifier")
        do {
            _ = try await harness.journal.reopenAfterProvenNoSave(jobID: job.id, captureID: selection.captureID,
                expectedRevision: job.revision, evidence: .authoritativeAbsence)
            XCTFail("Stale absence erased newly discovered evidence")
        } catch {
            XCTAssertEqual(error as? ImportJournalError, .staleRevision)
        }
        let survived = try await harness.job(job.id)
        XCTAssertEqual(survived.captures[0].placeholderAssetID, "new-identifier")
        XCTAssertEqual(survived.captures[0].originals, job.captures[0].originals)
    }

    func testBackgroundDuringExplicitRetryProbeStopsNewPhotosSubmission() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let selection = harness.selection(1)
        let job = try await seed(.submitting, with: harness, selection: selection)
        let gate = ImportTestGate()
        await harness.photos.setSearch(.authoritative([]))
        await harness.photos.holdNextSearch(at: gate)
        let retry = Task { try await harness.coordinator.retryCapture(jobID: job.id) }
        await gate.waitUntilEntered()
        await harness.coordinator.pause(jobID: job.id, reason: .backgrounded)
        await gate.release()
        await assertImportThrows { try await retry.value }
        let paused = try await harness.job(job.id)
        XCTAssertEqual(paused.pauseReason, .backgrounded)
        XCTAssertEqual(paused.captures[0].originals, job.captures[0].originals)
        let creates = await harness.photos.submittedPaths.count
        XCTAssertEqual(creates, 0)
    }

    func testRecoveryAtEveryPreSubmissionBoundaryWaitsForExplicitResume() async throws {
        for stage in [ImportStage.queued, .downloading, .validating, .readyToSave] {
            let harness = try CameraImportHarness()
            defer { harness.fixture.cleanUp() }
            let selection = harness.selection(1)
            let job = try await seed(stage, with: harness, selection: selection)
            let partial = harness.fixture.root.appendingPathComponent("staging/\(UUID()).part")
            try Data([1]).write(to: partial)
            let reopened = try harness.reopened()
            await reopened.reconcile()
            XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
            let creates = await harness.photos.submittedPaths.count
            XCTAssertEqual(creates, 0)
            let fresh = harness.session([harness.selection(1, sessionID: UUID(), handleOffset: 100)])
            try await reopened.resume(jobID: job.id, session: fresh)
            _ = await importEvent(reopened, jobID: job.id) { $0.receipts.count == 1 && !$0.isRunning }
            let paths = await harness.photos.submittedPaths.last
            for original in job.captures[0].originals { XCTAssertTrue(paths?.contains(original.relativePath) == true) }
        }
    }

    func testReceiptDedupSurvivesActualForgetAndNewCameraUUID() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let namespace = "FujiStudio.Tests.ImportReceipt.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        defer { defaults.removePersistentDomain(forName: namespace) }
        let camera = harness.fixture.camera
        let store = KeychainCameraStore(defaults: defaults, service: namespace,
                                        keychain: ReplayCameraKeychain(service: namespace))
        let peripheral = UUID()
        let saved = try store.savePaired(.init(id: camera.cameraID, peripheralID: peripheral, model: .xt5,
                                               displayName: "Test camera"), peerKey: camera.protocolPeerKey)
        let first = harness.selection(1)
        let receipt = try await importOne(first, with: harness, through: harness.coordinator)
        try await store.forget(saved.id)
        let newID = WirelessCameraID()
        _ = try store.savePaired(.init(id: newID, peripheralID: peripheral, model: .xt5,
                                      displayName: "Test camera"), peerKey: camera.protocolPeerKey)
        let repaired = WirelessIdentity(cameraID: newID, model: .xt5, firmware: camera.firmware,
                                        protocolPeerKey: camera.protocolPeerKey)
        let repeated = harness.selection(1, sessionID: UUID(), camera: repaired)
        XCTAssertNotEqual(first.captureID, repeated.captureID)
        let relaunched = try harness.reopened()
        let repeatedReceipt = try await importOne(repeated, with: harness, through: relaunched)
        XCTAssertEqual(repeatedReceipt.assetID, receipt.assetID)
        XCTAssertEqual(repeatedReceipt.fingerprints, receipt.fingerprints)
        let creations = await harness.photos.submittedPaths.count
        XCTAssertEqual(creations, 1)
    }

    func testFullyStagedLocalRetryRequiresSpaceForBothPhotosCopies() async throws {
        let harness = try CameraImportHarness(availableCapacity: { 64 * 1024 * 1024 })
        defer { harness.fixture.cleanUp() }
        let job = try await seed(.readyToSave, with: harness, selection: harness.selection(1))
        let reopened = try harness.reopened()
        await reopened.reconcile()
        try await reopened.retryCapture(jobID: job.id)
        let paused = await importEvent(reopened, jobID: job.id) { !$0.isRunning }
        XCTAssertEqual(paused?.pauseReason, .storage)
        XCTAssertEqual(paused?.stage, .readyToSave)
        let creates = await harness.photos.submittedPaths.count
        XCTAssertEqual(creates, 0)
        XCTAssertEqual(try harness.stagedFiles().count, 2)
    }

    func testRecoverySnapshotKeepsOlderUnresolvedJobBeyondProgressBuffer() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let selection = harness.selection(1, pair: false)
        let unresolved = try await seed(.submitting, with: harness, selection: selection)
        for index in 0..<66 {
            var job = try ImportJob(selections: [selection], importDate: Date(timeIntervalSinceReferenceDate: Double(index)))
            let original = try await harness.staging.write(object: selection.descriptors[0],
                session: ImportFileSession(bytes: harness.fixture.raf))
            job.captures[0].stage = .readyToSave
            job.captures[0].originals = [original]
            job = try await harness.journal.save(job)
            try await harness.journal.recordReceipt(.init(captureID: selection.captureID, fingerprints: [original.fingerprint],
                assetID: "history-\(index)", verifiedAt: job.importDate), jobID: job.id)
        }

        let reopened = try harness.reopened()
        await reopened.reconcile()
        let snapshot = await reopened.recoverySnapshot()
        XCTAssertEqual(snapshot.map(\.jobID), [Optional(unresolved.id)])
        XCTAssertEqual(snapshot.first?.actions.contains(.managePhotos), true)
        XCTAssertEqual(snapshot.first?.retainedBytes, UInt64(harness.fixture.raf.count))
    }

    func testSameFilenameAndLengthWithDifferentDownloadedHashCreatesNewAsset() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let selection = harness.selection(1)
        let old = try await importOne(selection, with: harness, through: harness.coordinator)
        let new = try await importOne(selection, with: harness, through: harness.coordinator, changedRAW: true)
        XCTAssertEqual(old.captureID, new.captureID)
        XCTAssertNotEqual(old.fingerprints, new.fingerprints)
        XCTAssertNotEqual(old.assetID, new.assetID)
    }

    func testFullAccessDeletionAllowsExplicitImportAndLimitedMissingAssetBlocks() async throws {
        for inspection in [ImportedAssetInspection.absent, .unavailable, .foundUnreadable] {
            let harness = try CameraImportHarness()
            defer { harness.fixture.cleanUp() }
            let selection = harness.selection(1)
            let receipt = try await importOne(selection, with: harness, through: harness.coordinator)
            await harness.photos.setInspection(inspection, for: receipt.assetID)
            let jobID = try await harness.coordinator.start([selection], session: harness.session([selection]))
            if inspection == .absent {
                _ = await importEvent(harness.coordinator, jobID: jobID) { $0.receipts.count == 1 && !$0.isRunning }
                let recreated = try await harness.job(jobID)
                XCTAssertNotEqual(recreated.captures[0].receipt?.assetID, receipt.assetID)
            } else {
                _ = await importEvent(harness.coordinator, jobID: jobID) { $0.pauseReason == .photosAccess && !$0.isRunning }
                let blocked = try await harness.job(jobID)
                XCTAssertEqual(blocked.captures[0].stage, .readyToSave)
                XCTAssertEqual(try harness.stagedFiles().count, 2)
            }
            let creates = await harness.photos.submittedPaths.count
            XCTAssertEqual(creates, inspection == .absent ? 2 : 1)
        }
    }

    func testReceiptLookupDistinguishesAssetStatusAndRequiresCompleteFingerprintEvidence() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let selection = harness.selection(1)
        let receipt = try await importOne(selection, with: harness, through: harness.coordinator)
        let recovery = ImportRecovery(journal: harness.journal, staging: harness.staging, gateway: harness.photos)
        let verified = await recovery.receiptStatus(for: receipt)
        XCTAssertEqual(verified, .verified)
        await harness.photos.setInspection(.unavailable, for: receipt.assetID)
        let limited = await recovery.receiptStatus(for: receipt)
        XCTAssertEqual(limited, .inaccessible)
        await harness.photos.setInspection(.absent, for: receipt.assetID)
        let removed = await recovery.receiptStatus(for: receipt)
        XCTAssertEqual(removed, .definitivelyDeleted)
        await harness.photos.setInspection(.found(.init(assetID: receipt.assetID, originals: [])), for: receipt.assetID)
        let changed = await recovery.receiptStatus(for: receipt)
        XCTAssertEqual(changed, .differentContent)
    }

    func testBrowserBadgeRequiresCurrentOriginalEvidenceAndLivePhotosReadback() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let selection = harness.selection(1)
        let receipt = try await importOne(selection, with: harness, through: harness.coordinator)
        let session = harness.session([selection])
        let recovery = ImportRecovery(journal: harness.journal, staging: harness.staging, gateway: harness.photos)
        let browser = CameraBrowserModel()
        await browser.load(session: session)
        let row = try XCTUnwrap(browser.captures.first)
        try await browser.refreshImportReceipts(using: recovery, originalFingerprints: [:])
        XCTAssertNil(browser.importReceiptStatus(for: row))
        let fingerprints = Dictionary(uniqueKeysWithValues: zip(selection.descriptors, receipt.fingerprints))
        try await browser.refreshImportReceipts(using: recovery, originalFingerprints: fingerprints)
        XCTAssertEqual(browser.importReceiptStatus(for: row), .verified)
        await harness.photos.setInspection(.unavailable, for: receipt.assetID)
        try await browser.refreshImportReceipts(using: recovery, originalFingerprints: fingerprints)
        XCTAssertEqual(browser.importReceiptStatus(for: row), .inaccessible)
        let downloaded = await session.handles
        XCTAssertTrue(downloaded.isEmpty)
        await browser.load(session: harness.session([harness.selection(1, sessionID: UUID(), handleOffset: 100)]))
        let freshRow = try XCTUnwrap(browser.captures.first)
        try await browser.refreshImportReceipts(using: recovery, originalFingerprints: fingerprints)
        XCTAssertNil(browser.importReceiptStatus(for: freshRow))
    }

    func testResumedImportProvesNewRoutesForCurrentBrowserBadge() async throws {
        let harness = try CameraImportHarness()
        defer { harness.fixture.cleanUp() }
        let original = harness.selection(1)
        let interrupted = harness.session([original], interrupt: .jpeg)
        let jobID = try await harness.coordinator.start([original], session: interrupted)
        _ = await importEvent(harness.coordinator, jobID: jobID) { $0.pauseReason == .connectionLost && !$0.isRunning }
        let currentSessionID = UUID()
        let resumed = harness.selection(1, sessionID: currentSessionID, handleOffset: 100)
        let session = harness.session([resumed])
        try await harness.coordinator.resume(jobID: jobID, session: session)
        _ = await importEvent(harness.coordinator, jobID: jobID) { $0.receipts.count == 1 && !$0.isRunning }
        await harness.coordinator.reconcile()

        let latestRun = await harness.coordinator.latestRunEvent(jobID: jobID)
        let run = try XCTUnwrap(latestRun)
        let evidence = try XCTUnwrap(run.routeEvidence)
        XCTAssertEqual(evidence.runID, run.runID)
        XCTAssertEqual(evidence.sessionID, currentSessionID)
        XCTAssertEqual(Set(evidence.fingerprints.keys), Set(resumed.descriptors))
        XCTAssertTrue(original.descriptors.allSatisfy { evidence.fingerprints[$0] == nil })

        let browser = CameraBrowserModel()
        await browser.load(session: session)
        let row = try XCTUnwrap(browser.captures.first)
        try await browser.refreshImportReceipts(using: harness.coordinator.recovery, originalFingerprints: evidence.fingerprints)
        XCTAssertEqual(browser.importReceiptStatus(for: row), .verified)
        let downloads = await session.handles
        XCTAssertEqual(downloads, [102, 103])
    }

    func testCompleteOrphanCleanupRequiresAllJournalsReadable() async throws {
        for corrupt in [false, true] {
            let harness = try CameraImportHarness()
            defer { harness.fixture.cleanUp() }
            let selection = harness.selection(1)
            let job = try await seed(.downloading, with: harness, selection: selection)
            let owned = try XCTUnwrap(job.captures[0].originals.first)
            let orphan = try await harness.staging.write(object: selection.descriptors[1],
                session: ImportFileSession(bytes: harness.fixture.jpeg))
            if corrupt {
                let other = harness.fixture.root.appendingPathComponent("journal/\(UUID()).json")
                try Data("unreadable JSON".utf8).write(to: other)
            }
            await harness.coordinator.reconcile()
            XCTAssertNoThrow(try harness.staging.fileURL(for: owned))
            XCTAssertEqual(FileManager.default.fileExists(atPath: harness.fixture.root
                .appendingPathComponent("staging/" + orphan.relativePath).path), corrupt)
        }
    }

    func testDurabilityFailureBeforeSubmittingPreventsPhotosCall() async throws {
        let journalDirectory = Mutex<URL?>(nil)
        let harness = try CameraImportHarness(beforeJournalReplace: {
            try journalDirectory.withLock { directory in
                if let root = directory, try Self.committedStage(.readyToSave, in: root) {
                    directory = nil
                    throw POSIXError(.ENOSPC)
                }
            }
        })
        defer { harness.fixture.cleanUp() }
        journalDirectory.withLock { $0 = harness.fixture.root.appendingPathComponent("journal") }
        let selection = harness.selection(1)
        let jobID = try await harness.coordinator.start([selection], session: harness.session([selection]))
        _ = await importEvent(harness.coordinator, jobID: jobID) { $0.pauseReason == .storage && !$0.isRunning }
        let creates = await harness.photos.submittedPaths.count
        XCTAssertEqual(creates, 0)
        let ready = try await harness.job(jobID)
        XCTAssertEqual(ready.captures[0].stage, .readyToSave)
        XCTAssertEqual(try harness.stagedFiles().count, 2)
    }

    func testReceiptReplacementMustBeDurableBeforeReleasingOriginals() async throws {
        let journalDirectory = Mutex<URL?>(nil)
        let harness = try CameraImportHarness(beforeJournalDirectorySync: {
            try journalDirectory.withLock { directory in
                if let directory, try Self.committedStage(.imported, in: directory) { throw POSIXError(.EIO) }
            }
        })
        defer { harness.fixture.cleanUp() }
        journalDirectory.withLock { $0 = harness.fixture.root.appendingPathComponent("journal") }
        let selection = harness.selection(1)
        let jobID = try await harness.coordinator.start([selection], session: harness.session([selection]))
        let blocked = await importEvent(harness.coordinator, jobID: jobID) { $0.recoveryRequired && !$0.isRunning }
        XCTAssertEqual(blocked?.receipts.count, 0)
        XCTAssertEqual(try harness.stagedFiles().count, 2)

        journalDirectory.withLock { $0 = nil }
        let reopened = try harness.reopened()
        await reopened.reconcile()
        let durable = try await harness.job(jobID)
        XCTAssertNotNil(durable.captures[0].receipt)
        XCTAssertTrue(try harness.stagedFiles().isEmpty)
        let creates = await harness.photos.submittedPaths.count
        XCTAssertEqual(creates, 1)
    }

    nonisolated private static func committedStage(_ stage: ImportStage, in root: URL) throws -> Bool {
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "json" {
            if try String(contentsOf: file, encoding: .utf8).contains("\"stage\":\"\(stage.rawValue)\"") { return true }
        }
        return false
    }

    private func seed(_ stage: ImportStage, with harness: CameraImportHarness,
                      selection: ImportSelection) async throws -> ImportJob {
        var job = try ImportJob(selections: [selection], importDate: .distantPast, mode: .xApp)
        let count = stage == .queued ? 0 : stage == .downloading ? 1 : 2
        for descriptor in selection.descriptors.prefix(count) {
            let bytes = descriptor.format == .raf ? harness.fixture.raf : harness.fixture.jpeg
            let original = try await harness.staging.write(object: descriptor, session: ImportFileSession(bytes: bytes))
            job.captures[0].originals.append(original)
        }
        job.captures[0].stage = stage
        return try await harness.journal.save(job)
    }

    private func snapshot(_ id: String, originals: [StagedOriginal]) -> ImportedAssetSnapshot {
        .init(assetID: id, originals: originals.map {
            .init(role: $0.role == .raf ? .alternate : .primary, format: $0.role, originalFilename: $0.originalFilename,
                  byteCount: $0.byteCount, sha256: $0.sha256)
        })
    }

    private func importOne(_ selection: ImportSelection, with harness: CameraImportHarness,
                           through coordinator: CameraImportCoordinator, changedRAW: Bool = false) async throws -> ImportReceipt {
        let jobID = try await coordinator.start([selection], session: harness.session([selection], changedRAW: changedRAW))
        let event = await importEvent(coordinator, jobID: jobID) { $0.receipts.count == 1 && !$0.isRunning }
        return try XCTUnwrap(event?.receipts.first)
    }
}
