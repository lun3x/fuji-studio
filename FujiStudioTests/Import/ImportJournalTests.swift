import Foundation
import FujiCameraCore
import Synchronization
import XCTest
@testable import FujiStudio

@MainActor
final class ImportJournalTests: XCTestCase {
    func testFrozenJobRecoversEachSaveBoundary() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let journalRoot = fixture.root.appendingPathComponent("journal", isDirectory: true)
        let staging = try ImportStagingStore(root: fixture.root.appendingPathComponent("staging", isDirectory: true))
        let journal = try ImportJournal(root: journalRoot)
        let selection = fixture.selection()
        let captureID = selection.captureID
        var job = try ImportJob(selections: [selection], importDate: Date(timeIntervalSince1970: 1_700_000_000), mode: .xApp)
        job = try await journal.save(job)
        let queued = try await reload(journalRoot)
        XCTAssertEqual(queued, job)
        XCTAssertEqual(queued.captures[0].stage, .queued)
        XCTAssertEqual(queued.captures[0].selection.descriptors, selection.descriptors)
        XCTAssertNil(queued.captures[0].selection.camera.protocolPeerKey)
        XCTAssertTrue(queued.camera.matches(fixture.camera, mode: .xApp))
        XCTAssertFalse(queued.camera.matches(queued.captures[0].selection.camera, mode: .xApp))
        XCTAssertFalse(queued.camera.matches(fixture.camera, mode: .autoSave))
        XCTAssertFalse(queued.camera.matches(.init(cameraID: fixture.camera.cameraID, model: .xt5,
            firmware: "4.32", protocolPeerKey: .init(bytes: Data([1, 2, 3]))), mode: .xApp))

        job.captures[0].stage = .downloading
        job = try await journal.save(job)
        let raw = try await staging.write(object: fixture.object(.raf), session: ImportFileSession(bytes: fixture.raf))
        job.captures[0].originals = [raw]
        job = try await journal.save(job)
        let afterRaw = try await reload(journalRoot)
        XCTAssertEqual(afterRaw.captures[0].originals, [raw])

        let jpeg = try await staging.write(object: fixture.object(), session: ImportFileSession(bytes: fixture.jpeg))
        job.captures[0].originals.append(jpeg)
        job.captures[0].stage = .submitting
        job = try await journal.save(job)
        let submitting = try await reload(journalRoot)
        XCTAssertEqual(submitting.captures[0].stage, .submitting)
        XCTAssertNil(submitting.captures[0].placeholderAssetID)

        try journal.placeholderWriter.persistPlaceholder(jobID: job.id, captureID: captureID, assetID: "placeholder")
        let withPlaceholder = try await reload(journalRoot)
        XCTAssertEqual(withPlaceholder.captures[0].placeholderAssetID, "placeholder")
        XCTAssertGreaterThan(withPlaceholder.revision, job.revision)
        let receipt = ImportReceipt(captureID: captureID, fingerprints: [raw.fingerprint, jpeg.fingerprint],
                                    assetID: "placeholder", verifiedAt: job.importDate)
        try await journal.recordReceipt(receipt, jobID: job.id)
        let complete = try await reload(journalRoot)
        XCTAssertEqual(complete.captures[0].stage, .imported)
        XCTAssertEqual(complete.captures[0].receipt, receipt)
        await assertImportThrows { _ = try await journal.save(submitting) }
        XCTAssertFalse(try Data(contentsOf: journalRoot.appendingPathComponent(job.id.uuidString + ".json"))
            .range(of: Data("camera-evidence-fixture".utf8)) != nil)
    }

    func testStaleJournalWriteCannotErasePlaceholderOrEscapeStaging() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let journalRoot = fixture.root.appendingPathComponent("journal", isDirectory: true)
        let stagingRoot = fixture.root.appendingPathComponent("staging", isDirectory: true)
        let staging = try ImportStagingStore(root: stagingRoot)
        let journal = try ImportJournal(root: journalRoot)
        let selection = fixture.selection(pair: false)
        let original = try await staging.write(object: fixture.object(.raf), session: ImportFileSession(bytes: fixture.raf))
        var job = try ImportJob(selections: [selection], importDate: .distantPast)
        job.captures[0].stage = .submitting
        job.captures[0].originals = [original]
        let snapshot = try await journal.save(job)
        let callback = journal.placeholderWriter
        let saveTask = Task.detached { try await journal.save(snapshot) }
        let callbackTask = Task.detached {
            try callback.persistPlaceholder(jobID: snapshot.id, captureID: selection.captureID, assetID: "asset")
        }
        try await callbackTask.value
        let saveResult = await saveTask.result
        do {
            _ = try await journal.save(snapshot)
            XCTFail("A snapshot that predates the placeholder must be stale")
        } catch {
            XCTAssertEqual(error as? ImportJournalError, .staleRevision)
        }
        let reloaded = try await reload(journalRoot)
        XCTAssertEqual(reloaded.captures[0].placeholderAssetID, "asset")
        switch saveResult {
        case .success(let saved):
            XCTAssertEqual(saved.revision, snapshot.revision + 1)
            XCTAssertEqual(reloaded.revision, saved.revision + 1)
        case .failure(let error):
            XCTAssertEqual(error as? ImportJournalError, .staleRevision)
            XCTAssertEqual(reloaded.revision, snapshot.revision + 1)
        }
        XCTAssertEqual(try staging.fileURL(for: original).deletingLastPathComponent().resolvingSymlinksInPath(),
                       stagingRoot.resolvingSymlinksInPath())
        var paused = reloaded
        paused.pauseReason = .backgrounded
        paused = try await journal.save(paused)
        XCTAssertEqual(paused.captures[0].stage, .submitting)
        var unsafe = paused
        unsafe.captures[0].stage = .paused
        unsafe.captures[0].originals = []
        await assertImportThrows { _ = try await journal.save(unsafe) }
        let afterUnsafe = try await reload(journalRoot)
        XCTAssertEqual(afterUnsafe, paused)
    }

    func testDiskFullBeforeReplacingEachBoundaryPreservesCommittedEvidence() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let journalRoot = fixture.root.appendingPathComponent("journal", isDirectory: true)
        let staging = try ImportStagingStore(root: fixture.root.appendingPathComponent("staging", isDirectory: true))
        let working = try ImportJournal(root: journalRoot)
        let failing = try ImportJournal(root: journalRoot, beforeReplace: { throw POSIXError(.ENOSPC) })
        let selection = fixture.selection(pair: false)
        var job = try ImportJob(selections: [selection], importDate: .distantPast)
        await assertImportThrows {
            _ = try await failing.save(job)
            XCTFail("Must never start download when the intent cannot persist")
        }
        let empty = try await working.loadJobs()
        XCTAssertTrue(empty.isEmpty)
        job = try await working.save(job)

        let raw = try await staging.write(object: fixture.object(.raf), session: ImportFileSession(bytes: fixture.raf))
        job.captures[0].originals = [raw]
        job.captures[0].stage = .readyToSave
        job = try await working.save(job)
        job.captures[0].stage = .submitting
        await assertImportThrows {
            _ = try await failing.save(job)
            XCTFail("Must never submit when the intent cannot persist")
        }
        let preSubmission = try await reload(journalRoot)
        XCTAssertEqual(preSubmission.captures[0].stage, .readyToSave)
        job = try await working.save(job)

        XCTAssertThrowsError(try failing.placeholderWriter.persistPlaceholder(
            jobID: job.id, captureID: selection.captureID, assetID: "asset"))
        let uncertain = try await reload(journalRoot)
        XCTAssertEqual(uncertain.captures[0].stage, .submitting)
        XCTAssertEqual(uncertain.captures[0].originals, [raw])
        try working.placeholderWriter.persistPlaceholder(jobID: job.id, captureID: selection.captureID, assetID: "asset")
        let receipt = ImportReceipt(captureID: selection.captureID, fingerprints: [raw.fingerprint],
                                    assetID: "asset", verifiedAt: job.importDate)
        await assertImportThrows { try await failing.recordReceipt(receipt, jobID: job.id) }
        let afterFailure = try await reload(journalRoot)
        XCTAssertEqual(afterFailure.captures[0].placeholderAssetID, "asset")
        XCTAssertNil(afterFailure.captures[0].receipt)
        XCTAssertEqual(try ResourceChecksum.sha256(staging.fileURL(for: raw)), raw.sha256)
    }

    func testVisiblePlaceholderAndReceiptRequireDirectorySyncBeforeAcknowledgement() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let journalRoot = fixture.root.appendingPathComponent("journal", isDirectory: true)
        let staging = try ImportStagingStore(root: fixture.root.appendingPathComponent("staging", isDirectory: true))
        let working = try ImportJournal(root: journalRoot)
        let selection = fixture.selection(pair: false)
        let raw = try await staging.write(object: fixture.object(.raf), session: ImportFileSession(bytes: fixture.raf))
        var job = try ImportJob(selections: [selection], importDate: .distantPast)
        job.captures[0].stage = .submitting
        job.captures[0].originals = [raw]
        job = try await working.save(job)
        let url = journalRoot.appendingPathComponent(job.id.uuidString + ".json")
        let blockSync = Mutex(true)
        let beforeDirectorySync: @Sendable () throws -> Void = {
            if blockSync.withLock({ $0 }) { throw POSIXError(.EIO) }
        }
        let failing = try ImportJournal(root: journalRoot, beforeDirectorySync: beforeDirectorySync)
        let reopened = try ImportJournal(root: journalRoot, beforeDirectorySync: beforeDirectorySync)

        XCTAssertThrowsError(try failing.placeholderWriter.persistPlaceholder(
            jobID: job.id, captureID: selection.captureID, assetID: "visible-placeholder")) {
                XCTAssertEqual($0 as? POSIXError, POSIXError(.EIO))
            }
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("visible-placeholder"))
        XCTAssertThrowsError(try reopened.placeholderWriter.persistPlaceholder(
            jobID: job.id, captureID: selection.captureID, assetID: "visible-placeholder"))
        await assertImportThrows { _ = try await reopened.loadJobs() }
        blockSync.withLock { $0 = false }
        try reopened.placeholderWriter.persistPlaceholder(jobID: job.id, captureID: selection.captureID,
                                                          assetID: "visible-placeholder")
        let withPlaceholder = try await reopened.loadJobs()
        XCTAssertEqual(withPlaceholder.first?.revision, job.revision + 1)
        XCTAssertEqual(withPlaceholder.first?.captures[0].placeholderAssetID, "visible-placeholder")

        let receipt = ImportReceipt(captureID: selection.captureID, fingerprints: [raw.fingerprint],
                                    assetID: "visible-placeholder", verifiedAt: job.importDate)
        blockSync.withLock { $0 = true }
        await assertImportThrows { try await failing.recordReceipt(receipt, jobID: job.id) }
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains(#""stage":"imported""#))
        await assertImportThrows { try await reopened.recordReceipt(receipt, jobID: job.id) }
        await assertImportThrows { _ = try await reopened.loadJobs() }
        XCTAssertEqual(try ResourceChecksum.sha256(staging.fileURL(for: raw)), raw.sha256)

        blockSync.withLock { $0 = false }
        try await reopened.recordReceipt(receipt, jobID: job.id)
        let completed = try await reopened.loadJobs()
        XCTAssertEqual(completed.first?.revision, job.revision + 2)
        XCTAssertEqual(completed.first?.captures[0].receipt, receipt)
    }

    func testCorruptAndUnknownSchemaAreQuarantinedAndKeepReportingRecoveryError() async throws {
        for data in [Data("not json".utf8), Data(#"{"schemaVersion":2}"#.utf8)] {
            let fixture = try ImportFileFixture()
            defer { fixture.cleanUp() }
            let journal = try ImportJournal(root: fixture.root)
            let url = fixture.root.appendingPathComponent(UUID().uuidString + ".json")
            try data.write(to: url)
            await assertImportThrows { _ = try await journal.loadJobs() }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            let quarantine = try XCTUnwrap(names.first { $0.hasSuffix(".quarantine") })
            XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(quarantine)), data)
            let reopened = try ImportJournal(root: fixture.root)
            await assertImportThrows { _ = try await reopened.loadJobs() }
        }
    }

    func testNegativeLengthInOtherwiseValidJournalIsQuarantined() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let journal = try ImportJournal(root: fixture.root)
        let job = try await journal.save(ImportJob(selections: [fixture.selection(pair: false)], importDate: .distantPast))
        let url = fixture.root.appendingPathComponent(job.id.uuidString + ".json")
        let data = try Data(contentsOf: url)
        let valid = try XCTUnwrap(String(data: data, encoding: .utf8))
        let negative = valid.replacingOccurrences(of: #""byteLength":"# + String(fixture.raf.count),
                                                   with: #""byteLength":-1"#)
        XCTAssertNotEqual(negative, valid)
        try Data(negative.utf8).write(to: url)
        await assertImportThrows { _ = try await journal.loadJobs() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func reload(_ root: URL) async throws -> ImportJob {
        let jobs = try await ImportJournal(root: root).loadJobs()
        return try XCTUnwrap(jobs.first)
    }
}
