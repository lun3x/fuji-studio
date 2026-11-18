import Foundation

enum ImportReceiptStatus: Equatable, Sendable {
    case verified
    case inaccessible
    case definitivelyDeleted
    case differentContent
}

/// Recovery operates on the protected journal, existing staged bytes and Photos reads.
/// The coordinator serializes it with queue transitions and with the only staging writer.
struct ImportRecovery: Sendable {
    let journal: ImportJournal
    let staging: ImportStagingStore
    let gateway: any PhotoImportGateway

    func receiptStatus(for receipt: ImportReceipt) async -> ImportReceiptStatus {
        guard !Task.isCancelled, let result = try? await gateway.inspect(assetID: receipt.assetID),
              !Task.isCancelled else { return .inaccessible }
        switch result {
        case .found(let asset):
            guard asset.assetID == receipt.assetID else { return .inaccessible }
            return asset.matches(receipt.fingerprints) ? .verified : .differentContent
        case .foundUnreadable, .unavailable:
            return .inaccessible
        case .absent:
            return .definitivelyDeleted
        }
    }

    /// Full observed fingerprints rank exact receipt candidates independently of camera UUID.
    func lookup(_ fingerprints: [ImportOriginalFingerprint], jobs: [ImportJob]) async
        -> (status: ImportReceiptStatus?, receipt: ImportReceipt?) {
        let expected = Set(fingerprints)
        var seen: Set<String> = []
        var status: ImportReceiptStatus?
        for job in jobs.reversed() {
            for receipt in job.captures.compactMap(\.receipt).reversed()
            where receipt.fingerprints.count == fingerprints.count && Set(receipt.fingerprints) == expected {
                guard seen.insert(receipt.assetID).inserted else { continue }
                let current = await receiptStatus(for: receipt)
                if current == .verified { return (.verified, receipt) }
                if status == nil || current == .inaccessible { status = current }
            }
        }
        return (status, nil)
    }

    func reconcile(_ job: ImportJob, at index: Int) async throws -> (ImportJob, ImportReconciliation) {
        let entry = job.captures[index]
        guard entry.stage.mayHaveSubmitted else { throw ImportJournalError.invalidTransition }
        // A missing or damaged local file cannot clear submission evidence.
        guard let capture = try? OriginalImportValidator(staging: staging)
            .validate(entry.selection, originals: entry.originals, importDate: job.importDate) else {
            return (job, entry.placeholderAssetID.map { .savedUnverified($0) } ?? .uncertain)
        }
        let result = await ImportPhotoVerifier(gateway: gateway)
            .reconcile(capture: capture, placeholder: entry.placeholderAssetID,
                       recheckingSettledSave: entry.stage == .savedUnverified && job.pauseReason == .unresolvedSave)
        switch result {
        case .verified(let receipt):
            try await journal.recordReceipt(receipt, jobID: job.id, expectedRevision: job.revision)
            let recorded = try await load(job.id)
            return (try await releaseCompletedFiles(recorded), result)
        case .savedUnverified:
            if entry.stage != .savedUnverified {
                var updated = job
                updated.captures[index].stage = .savedUnverified
                return (try await journal.save(updated), result)
            }
        case .uncertain, .definitivelyAbsent:
            break
        }
        return (job, result)
    }

    func load(_ jobID: UUID) async throws -> ImportJob {
        guard let job = try await journal.loadJobs().first(where: { $0.id == jobID }) else {
            throw CameraImportError.missingJob
        }
        return job
    }

    func releaseCompletedFiles(_ job: ImportJob) async throws -> ImportJob {
        var updated = job
        for index in updated.captures.indices {
            let capture = updated.captures[index]
            guard capture.isFinished, !capture.originals.isEmpty else { continue }
            for original in capture.originals { try staging.remove(original) }
            updated.captures[index].originals.removeAll()
        }
        if updated == job { return job }
        return try await journal.save(updated)
    }

    /// Never infer ownership from filenames. A complete, readable journal set is required.
    func removeInterruptedFiles() async throws -> [ImportJob] {
        let jobs = try await journal.loadJobs()
        let originals = Set(jobs.flatMap(\.captures).flatMap(\.originals).map(\.relativePath))
        try staging.removeInterruptedDownloads()
        try staging.removeUnreferencedOriginals(retaining: originals)
        return jobs
    }
}
