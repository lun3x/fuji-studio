import Darwin
import Foundation

enum ImportJournalError: Error, Equatable, Sendable {
    case invalidJob, invalidTransition, staleRevision, missingJob, recoveryRequired
}

enum ImportNoSaveEvidence: Equatable, Sendable {
    /// The submitting intent was recorded, but the gateway did not issue a change.
    case rejectedBeforeIssuance
    /// A reconciliation of this exact submission revision proved authoritative absence.
    case authoritativeAbsence
}

/// Queue transitions and the native Photos callback use the same durable store. Retain the
/// returned revision after each save. Reload after a placeholder/receipt update or stale save.
actor ImportJournal {
    nonisolated let placeholderWriter: ImportJournalStore

    init(root: URL = ImportDisk.root("journal"),
         beforeReplace: @escaping @Sendable () throws -> Void = {},
         beforeDirectorySync: @escaping @Sendable () throws -> Void = {}) throws {
        placeholderWriter = try ImportJournalStore(root: root, beforeReplace: beforeReplace,
                                                   beforeDirectorySync: beforeDirectorySync)
    }

    @discardableResult
    func save(_ job: ImportJob) throws -> ImportJob {
        try placeholderWriter.save(job)
    }

    func loadJobs() throws -> [ImportJob] {
        try placeholderWriter.loadJobs()
    }

    func recordPlaceholder(jobID: UUID, captureID: CameraCaptureID, assetID: String) throws {
        try placeholderWriter.persistPlaceholder(jobID: jobID, captureID: captureID, assetID: assetID)
    }

    func recordReceipt(_ receipt: ImportReceipt, jobID: UUID, expectedRevision: UInt64? = nil) throws {
        try placeholderWriter.recordReceipt(receipt, jobID: jobID, expectedRevision: expectedRevision)
    }

    func reopenAfterProvenNoSave(jobID: UUID, captureID: CameraCaptureID, expectedRevision: UInt64,
                               evidence: ImportNoSaveEvidence) throws -> ImportJob {
        try placeholderWriter.reopenAfterProvenNoSave(jobID: jobID, captureID: captureID,
                                                       expectedRevision: expectedRevision, evidence: evidence)
    }
}

final class ImportJournalStore: Sendable {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let job: ImportJob.Snapshot
    }

    private struct Header: Decodable { let schemaVersion: Int }

    // Serializes read/modify/replace even if the app reopens the same journal root.
    private static let lock = NSLock()
    private let disk: ImportDisk
    private let beforeReplace: @Sendable () throws -> Void
    private let beforeDirectorySync: @Sendable () throws -> Void

    fileprivate init(root: URL, beforeReplace: @escaping @Sendable () throws -> Void,
                     beforeDirectorySync: @escaping @Sendable () throws -> Void) throws {
        disk = try ImportDisk(root: root)
        self.beforeReplace = beforeReplace
        self.beforeDirectorySync = beforeDirectorySync
    }

    fileprivate func loadJobs() throws -> [ImportJob] {
        try Self.lock.withLock {
            let files = try journalFiles()
            let jobs = try files.map(read).sorted {
                if $0.importDate != $1.importDate { return $0.importDate < $1.importDate }
                return $0.id.uuidString < $1.id.uuidString
            }
            // A prior process may have renamed a file and failed before flushing the entry.
            // A successful sync is required before the caller can act on any visible receipt.
            try synchronizeDirectory()
            return jobs
        }
    }

    fileprivate func save(_ job: ImportJob) throws -> ImportJob {
        try Self.lock.withLock {
            try job.validate()
            if let current = try currentJob(job.id) {
                guard job.revision == current.revision else { throw ImportJournalError.staleRevision }
                guard job.camera == current.camera, job.importDate == current.importDate,
                      job.frozenSelections == current.frozenSelections,
                      zip(job.captures, current.captures).allSatisfy({ $0.preservesSaveEvidence(from: $1) }) else {
                    throw ImportJournalError.invalidTransition
                }
            } else if job.revision != 0 {
                throw ImportJournalError.staleRevision
            }
            return try persistNext(job)
        }
    }

    /// Called within PhotoKit's synchronous changes block. This takes a lock rather than
    /// awaiting actor work. A thrown write leaves submitting intent and staged bytes intact.
    func persistPlaceholder(jobID: UUID, captureID: CameraCaptureID, assetID: String) throws {
        _ = try edit(jobID: jobID, captureID: captureID) { capture in
            if capture.placeholderAssetID == assetID { return }
            try capture.setPlaceholder(assetID)
        }
    }

    fileprivate func recordReceipt(_ receipt: ImportReceipt, jobID: UUID, expectedRevision: UInt64?) throws {
        _ = try edit(jobID: jobID, captureID: receipt.captureID, expectedRevision: expectedRevision) { capture in
            if capture.receipt == receipt { return }
            try capture.verify(receipt)
        }
    }

    fileprivate func reopenAfterProvenNoSave(jobID: UUID, captureID: CameraCaptureID, expectedRevision: UInt64,
                                              evidence: ImportNoSaveEvidence) throws -> ImportJob {
        try edit(jobID: jobID, captureID: captureID, expectedRevision: expectedRevision) {
            try $0.reopenAfterProvenNoSave(evidence)
        }
    }

    private func edit(jobID: UUID, captureID: CameraCaptureID, expectedRevision: UInt64? = nil,
                      _ change: (inout ImportCaptureProgress) throws -> Void) throws -> ImportJob {
        try Self.lock.withLock {
            guard var job = try currentJob(jobID),
                  let index = job.captures.firstIndex(where: { $0.id == captureID }) else {
                throw ImportJournalError.missingJob
            }
            guard expectedRevision == nil || expectedRevision == job.revision else {
                throw ImportJournalError.staleRevision
            }
            let current = job.captures[index]
            try change(&job.captures[index])
            if job.captures[index] != current {
                try job.validate()
                return try persistNext(job)
            } else {
                // An identical retry can see a replacement whose previous sync failed.
                try synchronizeDirectory()
                return job
            }
        }
    }

    private func url(_ id: UUID) -> URL { disk.root.appendingPathComponent(id.uuidString + ".json") }

    private func journalFiles() throws -> [URL] {
        let files = try FileManager.default.contentsOfDirectory(at: disk.root, includingPropertiesForKeys: nil)
        guard !files.contains(where: { $0.pathExtension == "quarantine" }) else {
            throw ImportJournalError.recoveryRequired
        }
        return files.filter { $0.pathExtension == "json" }
    }

    private func currentJob(_ id: UUID) throws -> ImportJob? {
        let target = url(id)
        return try journalFiles().contains(where: { $0.lastPathComponent == target.lastPathComponent }) ? read(target) : nil
    }

    private func read(_ file: URL) throws -> ImportJob {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { try quarantine(file) }
        // Read failures (locked protection class, I/O) are distinct from corrupt records.
        let data = try Data(contentsOf: file)
        do {
            let decoder = JSONDecoder()
            guard try decoder.decode(Header.self, from: data).schemaVersion == 1 else {
                throw ImportJournalError.recoveryRequired
            }
            let job = try ImportJob(snapshot: decoder.decode(Envelope.self, from: data).job)
            guard job.revision > 0, file.lastPathComponent == url(job.id).lastPathComponent else {
                throw ImportJournalError.recoveryRequired
            }
            return job
        } catch {
            try quarantine(file)
        }
    }

    private func quarantine(_ file: URL) throws -> Never {
        let destination = disk.root.appendingPathComponent(UUID().uuidString + ".quarantine")
        try disk.rename(file, to: destination, replacing: false)
        try synchronizeDirectory()
        throw ImportJournalError.recoveryRequired
    }

    private func persistNext(_ job: ImportJob) throws -> ImportJob {
        guard job.revision < UInt64.max else { throw ImportJournalError.invalidJob }
        let next = job.replacingRevision(job.revision + 1)
        let data = try JSONEncoder().encode(Envelope(schemaVersion: 1, job: .init(next)))
        let (temporary, handle) = try disk.createFile(named: UUID().uuidString + ".pending")
        defer { try? FileManager.default.removeItem(at: temporary) }
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try beforeReplace()
        try disk.rename(temporary, to: url(job.id))
        try synchronizeDirectory()
        return next
    }

    private func synchronizeDirectory() throws {
        try beforeDirectorySync()
        try disk.synchronizeDirectory()
    }
}
