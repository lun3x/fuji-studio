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

    /// Restore an earlier Photos pair only when a member was confirmed in the selected camera session,
    /// both local originals match the same receipt and Photos confirms the previous asset was deleted.
    func stageDeletedPair(_ job: ImportJob, at index: Int, history: [ImportJob],
                          cache: CameraOriginalCache) async throws -> ImportJob {
        let capture = job.captures[index]
        let objects = capture.selection.descriptors
        guard capture.stage == .queued, capture.originals.isEmpty, capture.selection.policy == .pair,
              objects.count == 2, objects.allSatisfy({ $0.captureDate != nil }) else { return job }
        let receipts = history.flatMap(\.captures).compactMap { previous -> ImportReceipt? in
            guard previous.id == capture.id, previous.stage == .imported,
                  previous.selection.descriptors.count == objects.count,
                  zip(previous.selection.descriptors, objects).allSatisfy({ $0.matchesOriginal($1) && $0.handle == $1.handle })
            else { return nil }
            return previous.receipt
        }
        guard let first = receipts.first, receipts.allSatisfy({ Set($0.fingerprints) == Set(first.fingerprints) })
        else { return job }
        for assetID in Set(receipts.map(\.assetID)) {
            guard await gateway.isDefinitelyAbsent(assetID: assetID) else { return job }
        }
        var entries: [CameraOriginalCache.Entry] = []
        for object in objects {
            guard let entry = try? await cache.localEntry(for: object),
                  entry.original.verifiedTransferMode == job.camera.mode else { return job }
            entries.append(entry)
        }
        guard zip(entries, objects).contains(where: { $0.original.descriptor == $1 }),
              Set(entries.map { $0.original.fingerprint }) == Set(first.fingerprints) else { return job }
        try Task.checkCancellation()
        var updated = job
        do {
            try staging.preflight(stagingByteLengths: [], photoCopyByteLengths: objects.map(\.byteLength))
            for (entry, object) in zip(entries, objects) {
                let original = try staging.link(entry.original, from: entry.url, for: object)
                updated.captures[index].originals.append(original)
            }
        } catch {
            for original in updated.captures[index].originals { try? staging.remove(original) }
            return job
        }
        updated.captures[index].stage = .readyToSave
        return try await journal.save(updated)
    }

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
