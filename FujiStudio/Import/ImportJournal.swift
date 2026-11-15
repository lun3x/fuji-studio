import Darwin
import Foundation

enum ImportJournalError: Error, Equatable, Sendable {
    case invalidJob, invalidTransition, staleRevision, missingJob, recoveryRequired
}

/// Queue transitions and the native Photos callback use the same durable store. Retain the
/// returned revision after each save. Reload after a placeholder/receipt update or stale save.
actor ImportJournal {
    nonisolated let placeholderWriter: ImportJournalStore

    init(root: URL = ImportDisk.root("journal"), beforeReplace: @escaping @Sendable () throws -> Void = {}) throws {
        placeholderWriter = try ImportJournalStore(root: root, beforeReplace: beforeReplace)
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

    func recordReceipt(_ receipt: ImportReceipt, jobID: UUID) throws {
        try placeholderWriter.recordReceipt(receipt, jobID: jobID)
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

    fileprivate init(root: URL, beforeReplace: @escaping @Sendable () throws -> Void) throws {
        disk = try ImportDisk(root: root)
        self.beforeReplace = beforeReplace
    }

    fileprivate func loadJobs() throws -> [ImportJob] {
        try Self.lock.withLock {
            let files = try journalFiles()
            return try files.map(read).sorted {
                if $0.importDate != $1.importDate { return $0.importDate < $1.importDate }
                return $0.id.uuidString < $1.id.uuidString
            }
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
        try edit(jobID: jobID, captureID: captureID) { capture in
            if capture.placeholderAssetID == assetID { return }
            try capture.setPlaceholder(assetID)
        }
    }

    fileprivate func recordReceipt(_ receipt: ImportReceipt, jobID: UUID) throws {
        try edit(jobID: jobID, captureID: receipt.captureID) { capture in
            if capture.receipt == receipt { return }
            try capture.verify(receipt)
        }
    }

    private func edit(jobID: UUID, captureID: CameraCaptureID, _ change: (inout ImportCaptureProgress) throws -> Void) throws {
        try Self.lock.withLock {
            guard var job = try currentJob(jobID),
                  let index = job.captures.firstIndex(where: { $0.id == captureID }) else {
                throw ImportJournalError.missingJob
            }
            let current = job.captures[index]
            try change(&job.captures[index])
            if job.captures[index] != current {
                try job.validate()
                _ = try persistNext(job)
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
        try disk.synchronizeDirectory()
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
        try disk.synchronizeDirectory()
        return next
    }
}
