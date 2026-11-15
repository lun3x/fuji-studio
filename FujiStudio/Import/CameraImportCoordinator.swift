import Foundation
import FujiCameraCore

/// One application-owned coordinator serializes all jobs, staging writes and recovery.
/// The caller retains ownership of the wireless session and lends it exclusively while
/// import uses it. Drain browser work before lending it. A pause stops admission and
/// cancels active camera I/O, which may invalidate the socket. The connection owner
/// may close it immediately on background/loss instead of waiting for import or Photos.
/// Keep a borrowed healthy session exclusive while paused for a local Retry/Skip.
actor CameraImportCoordinator {
    private struct Run {
        let id = UUID()
        var job: ImportJob
        var worker: Task<Void, Never>?
        var requestedPause: ImportPauseReason?
        var sessionID: UUID?
        var invalidatedSession = false
        var isUsingCamera = false
        var isVerifyingPhotos = false
        var componentID: UUID?
        var componentBytes: UInt64 = 0
        var verifiedRoutes: [WirelessObjectDescriptor: ImportOriginalFingerprint] = [:]

        var routeEvidence: ImportRouteEvidence? {
            guard !invalidatedSession, let sessionID, !verifiedRoutes.isEmpty else { return nil }
            return .init(runID: id, sessionID: sessionID, fingerprints: verifiedRoutes)
        }

        mutating func recordRoutes(for capture: ValidatedCapture) {
            guard !invalidatedSession, let sessionID,
                  capture.originals.allSatisfy({ $0.descriptor.sessionID == sessionID }) else { return }
            for original in capture.originals {
                verifiedRoutes[original.descriptor] = original.fingerprint
            }
        }
    }

    private struct Loan {
        let jobID: UUID
        let session: any WirelessTransferSession
    }

    private struct Command {
        let jobID: UUID?
        var requestedPause: ImportPauseReason?
    }

    private let journal: ImportJournal
    private let staging: ImportStagingStore
    private let gateway: any PhotoImportGateway
    nonisolated let recovery: ImportRecovery

    private var run: Run?
    private var loan: Loan?
    private var retiredSessions: Set<UUID> = []
    private var command: Command?
    private var reconcileRequested = false
    private var sequence: UInt64 = 0
    private var latest: [UUID: ImportEvent] = [:]
    private var latestRunEvents: [UUID: ImportEvent] = [:]
    private var journalIssue: ImportEvent?
    private var listeners: [UUID: AsyncStream<ImportEvent>.Continuation] = [:]

    init(journal: ImportJournal, staging: ImportStagingStore, gateway: any PhotoImportGateway) {
        self.journal = journal
        self.staging = staging
        self.gateway = gateway
        recovery = .init(journal: journal, staging: staging, gateway: gateway)
    }

    func events() -> AsyncStream<ImportEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: ImportEvent.self, bufferingPolicy: .bufferingNewest(64))
        listeners[id] = continuation
        continuation.onTermination = { [weak self] _ in Task { await self?.removeListener(id) } }
        let snapshots = Array(latest.values) + (journalIssue.map { [$0] } ?? [])
        for event in snapshots.sorted(by: { $0.sequence < $1.sequence }) { continuation.yield(event) }
        return stream
    }

    /// Read after start/resume to bind the run to the caller's connection generation.
    /// This includes an already-settled run, even after foreground reconciliation.
    func latestRunEvent(jobID: UUID) -> ImportEvent? { latestRunEvents[jobID] }

    /// Read after reconciliation for every unfinished job, independent of the live event buffer.
    func recoverySnapshot() -> [ImportEvent] {
        latest.values.filter { $0.captureIndex != nil }.sorted { $0.sequence < $1.sequence }
    }

    private func removeListener(_ id: UUID) {
        listeners[id] = nil
    }

    /// The session must already have completed browsing. A new job must use the same
    /// routes the user selected. A resumed job can rematch fresh session routes.
    func start(_ selections: [ImportSelection], session: any WirelessTransferSession) async throws -> UUID {
        let jobID = UUID()
        try beginCommand(jobID: jobID)
        defer { endCommand() }
        guard let first = selections.first else { throw ImportJournalError.invalidJob }
        _ = try await recovery.removeInterruptedFiles()
        let camera = try await session.open()
        try Self.requireSupported(camera)
        let capabilities = try await session.capabilities()
        guard first.camera == camera else { throw WirelessFailure.peerMismatch }
        guard capabilities.originalSizeVerified, selections.allSatisfy({ selection in
            selection.descriptors.allSatisfy { $0.byteLength <= UInt32.max }
        }) else { throw WirelessFailure.originalSizeUnavailable }
        let job = try ImportJob(id: jobID, selections: selections, importDate: Date(), mode: capabilities.mode)
        try Task.checkCancellation()
        let committed = try await journal.save(job)
        try await admit(committed, session: session, requireOriginalRoutes: true)
        return committed.id
    }

    func resume(jobID: UUID, session: any WirelessTransferSession) async throws {
        try beginCommand(jobID: jobID)
        defer { endCommand() }
        let jobs = try await recovery.removeInterruptedFiles()
        guard var job = jobs.first(where: { $0.id == jobID }), let index = job.nextCaptureIndex else {
            throw CameraImportError.missingJob
        }
        guard !job.captures[index].stage.mayHaveSubmitted else {
            throw CameraImportError.unresolvedSave(retainedBytes: job.retainedBytes)
        }
        guard job.pauseReason != .freshSelectionRequired else { throw CameraImportError.freshSelectionRequired }
        job = try await clearPause(job)
        try await admit(job, session: session)
    }

    func retryCapture(jobID: UUID) async throws {
        try beginCommand(jobID: jobID)
        defer { endCommand() }
        var job = try await recovery.load(jobID)
        guard let index = job.nextCaptureIndex, job.pauseReason != .freshSelectionRequired else {
            throw CameraImportError.actionUnavailable
        }
        if job.captures[index].stage.mayHaveSubmitted {
            let (reconciled, result) = try await recovery.reconcile(job, at: index)
            job = reconciled
            switch result {
            case .definitivelyAbsent:
                job = try await journal.reopenAfterProvenNoSave(jobID: jobID, captureID: job.captures[index].id,
                    expectedRevision: job.revision, evidence: .authoritativeAbsence)
            case .verified:
                break
            case .savedUnverified, .uncertain:
                job = try await setPause(.unresolvedSave, on: job)
                publish(job)
                throw CameraImportError.unresolvedSave(retainedBytes: job.retainedBytes)
            }
        }
        let session = session(for: jobID)
        guard let next = job.nextCaptureIndex else {
            job = try await clearPause(job)
            publish(job)
            return
        }
        guard session != nil || job.captures[next].stage == .readyToSave else {
            publish(job)
            throw CameraImportError.sessionRequired
        }
        job = try await clearPause(job)
        try await admit(job, session: session, retryLocalFirst: true)
    }

    func skipCapture(jobID: UUID) async throws {
        try beginCommand(jobID: jobID)
        defer { endCommand() }
        var job = try await recovery.load(jobID)
        guard let index = job.nextCaptureIndex else { throw CameraImportError.actionUnavailable }
        guard !job.captures[index].stage.mayHaveSubmitted else {
            throw CameraImportError.unresolvedSave(retainedBytes: job.retainedBytes)
        }
        job.captures[index].stage = .skipped
        job = try await recovery.releaseCompletedFiles(journal.save(job))
        if let session = session(for: jobID), job.nextCaptureIndex != nil, job.pauseReason != .freshSelectionRequired {
            job = try await clearPause(job)
            try await admit(job, session: session)
        } else {
            loan = loan?.jobID == jobID ? nil : loan
            let remainingPause: ImportPauseReason = job.pauseReason == .freshSelectionRequired
                ? .freshSelectionRequired : .interrupted
            job = try await setPause(job.nextCaptureIndex == nil ? nil : remainingPause, on: job)
            publish(job)
        }
    }

    func discardRemaining(jobID: UUID) async throws {
        try beginCommand(jobID: jobID)
        defer { endCommand() }
        var job = try await recovery.load(jobID)
        guard !job.captures.contains(where: { $0.stage.mayHaveSubmitted }) else {
            throw CameraImportError.unresolvedSave(retainedBytes: job.retainedBytes)
        }
        for index in job.captures.indices where !job.captures[index].isFinished {
            job.captures[index].stage = .skipped
        }
        job.pauseReason = nil
        job = try await recovery.releaseCompletedFiles(journal.save(job))
        try staging.removeInterruptedDownloads()
        if loan?.jobID == jobID { loan = nil }
        publish(job)
    }

    func pause(jobID: UUID) async {
        await pause(jobID: jobID, reason: .userRequested)
    }

    /// Background and link-loss callers should initiate connection cleanup independently
    /// and concurrently, then wait for this method before handing the camera to new work.
    func pause(jobID: UUID, reason: ImportPauseReason) async {
        await stop(jobID: jobID, reason: reason)
    }

    func cancelRemaining(jobID: UUID) async {
        await stop(jobID: jobID, reason: .cancelled)
    }

    private func stop(jobID: UUID, reason: ImportPauseReason) async {
        if let active = run, active.job.id == jobID {
            run?.requestedPause = reason
            let lostSession = reason == .connectionLost || reason == .backgrounded
            if active.isUsingCamera || (session(for: jobID) != nil && lostSession) {
                retireSession()
            }
            if loan?.jobID == jobID { loan = nil }
            if active.isUsingCamera { active.worker?.cancel() }
            publish(active.job)
            await active.worker?.value
            return
        }
        if loan?.jobID == jobID { loan = nil }
        if command?.jobID == jobID { command?.requestedPause = reason }
        guard run == nil, command == nil else { return }
        command = .init(jobID: jobID)
        defer { endCommand() }
        do {
            var job = try await recovery.load(jobID)
            guard let index = job.nextCaptureIndex else { return }
            if job.captures[index].stage.mayHaveSubmitted {
                let (settled, result) = try await recovery.reconcile(job, at: index)
                job = settled
                let unresolved = job.captures[index].stage.mayHaveSubmitted
                job = try await setPause(unresolved ? .unresolvedSave : reason, on: job)
                publish(job, retryableSubmission: result == .definitivelyAbsent)
            } else {
                job = try await setPause(reason, on: job)
                try staging.removeInterruptedDownloads()
                publish(job)
            }
        } catch {
            publishJournalIssue()
        }
    }

    /// Foreground reconciliation may inspect Photos and release resolved local files.
    /// A request during a live transfer is deferred until there is no staging writer.
    func reconcile() async {
        guard run == nil, command == nil else {
            reconcileRequested = true
            return
        }
        command = .init(jobID: nil)
        reconcileRequested = false
        defer { endCommand() }
        do {
            let jobs = try await recovery.removeInterruptedFiles()
            journalIssue = nil
            for var job in jobs {
                var retryableSubmission = false
                job = try await recovery.releaseCompletedFiles(job)
                for index in job.captures.indices where job.captures[index].stage.mayHaveSubmitted {
                    let (settled, result) = try await recovery.reconcile(job, at: index)
                    job = settled
                    if index == job.nextCaptureIndex { retryableSubmission = result == .definitivelyAbsent }
                }
                if job.captures.contains(where: { $0.stage.mayHaveSubmitted }) {
                    job = try await setPause(.unresolvedSave, on: job)
                } else if job.nextCaptureIndex == nil {
                    job = try await clearPause(job)
                } else if job.pauseReason == nil || job.pauseReason == .unresolvedSave {
                    job = try await setPause(.interrupted, on: job)
                }
                publish(job, retryableSubmission: retryableSubmission)
            }
        } catch {
            publishJournalIssue()
        }
    }

    private func beginCommand(jobID: UUID) throws {
        guard run == nil, command == nil else { throw CameraImportError.busy }
        command = .init(jobID: jobID)
    }

    private func endCommand() {
        command = nil
        scheduleReconcile()
    }

    private func scheduleReconcile() {
        if reconcileRequested, run == nil, command == nil {
            Task { await self.reconcile() }
        }
    }

    private func session(for jobID: UUID) -> (any WirelessTransferSession)? {
        loan?.jobID == jobID ? loan?.session : nil
    }

    private func admit(_ job: ImportJob, session: (any WirelessTransferSession)?, requireOriginalRoutes: Bool = false,
                       retryLocalFirst: Bool = false) async throws {
        if command?.requestedPause != nil || Task.isCancelled {
            let paused = try await setPause(command?.requestedPause ?? .interrupted, on: job)
            publish(paused)
            throw CancellationError()
        }
        loan = session.map { .init(jobID: job.id, session: $0) }
        run = .init(job: job)
        if requireOriginalRoutes { run?.sessionID = job.frozenSelections.first?.descriptors.first?.sessionID }
        run?.worker = Task {
            await self.process(job, session: session, requireOriginalRoutes: requireOriginalRoutes, retryLocalFirst: retryLocalFirst)
        }
        publish(job)
    }

    private func process(_ job: ImportJob, session: (any WirelessTransferSession)?, requireOriginalRoutes: Bool,
                         retryLocalFirst: Bool) async {
        var current = job
        var failure: WirelessFailure?
        var reason: ImportPauseReason?
        var retryableSubmission = false
        var inventory: ImportInventory?
        var localFirst = retryLocalFirst
        do {
            while let index = current.nextCaptureIndex {
                try checkRunning()
                let stage = current.captures[index].stage
                guard !stage.mayHaveSubmitted else {
                    throw CameraImportError.unresolvedSave(retainedBytes: current.retainedBytes)
                }
                if let session, !(localFirst && stage == .readyToSave) {
                    if inventory == nil {
                        inventory = try await withCameraWork { try await ImportInventory.read(session, for: job.camera) }
                        run?.sessionID = inventory?.sessionID
                        if let sessionID = inventory?.sessionID, retiredSessions.contains(sessionID) {
                            retireSession()
                            throw WirelessFailure.connectionLost
                        }
                    }
                    guard let inventory else { throw WirelessFailure.connectionLost }
                    let objects = try inventory.match(current.captures[index].selection,
                                                      requireOriginalRoutes: requireOriginalRoutes)
                    current = try await download(current, at: index, objects: objects, session: session)
                } else if stage != .readyToSave {
                    reason = .interrupted
                    break
                }
                localFirst = false
                try checkRunning()
                let entry = current.captures[index]
                let validated = try OriginalImportValidator(staging: staging)
                    .validate(entry.selection, originals: entry.originals, importDate: current.importDate)
                run?.recordRoutes(for: validated)
                if entry.stage != .readyToSave {
                    current.captures[index].stage = .readyToSave
                    current = try await save(current)
                }
                let outcome = try await saveToPhotos(validated, job: current, at: index)
                current = outcome.job
                reason = outcome.pauseReason
                retryableSubmission = outcome.retryableSubmission
                if reason != nil { break }
            }
        } catch is CancellationError {
            reason = run?.requestedPause ?? .connectionLost
        } catch {
            failure = Self.wirelessFailure(for: error)
            reason = Self.pauseReason(for: failure ?? error)
            if reason == .freshSelectionRequired, loan != nil { retireSession() }
        }

        // A callback or receipt write can advance the revision even when subsequent I/O fails.
        // Reload before attempting to persist the final pause or publish another snapshot.
        do {
            current = try await recovery.load(job.id)
            current = try await recovery.releaseCompletedFiles(current)
            let requested = run?.requestedPause
            if current.captures.contains(where: { $0.stage.mayHaveSubmitted }) {
                reason = .unresolvedSave
            } else if reason != .freshSelectionRequired {
                reason = requested ?? reason
            }
            if requested != nil || failure != nil || reason == .journalUnavailable || current.nextCaptureIndex == nil {
                loan = nil
            }
            current = try await setPause(current.nextCaptureIndex == nil ? nil : reason, on: current)
            if let latestPause = run?.requestedPause, latestPause != requested,
               reason != .unresolvedSave, reason != .freshSelectionRequired, current.nextCaptureIndex != nil {
                current = try await setPause(latestPause, on: current)
                reason = latestPause
            }
        } catch {
            loan = nil
            reason = .journalUnavailable
            publishJournalIssue()
        }
        let completed = run
        run = nil
        publish(current, requestedPause: reason, wirelessFailure: failure, retryableSubmission: retryableSubmission,
                runID: completed?.id, invalidatedSession: completed?.invalidatedSession == true,
                routeEvidence: completed?.routeEvidence)
        scheduleReconcile()
    }

    private func download(_ job: ImportJob, at index: Int, objects: [WirelessObjectDescriptor],
                          session: any WirelessTransferSession) async throws -> ImportJob {
        var job = job
        let contains = job.captures[index].originals
        let remaining = objects.filter { object in !contains.contains(where: { $0.describes(object) }) }
        if !remaining.isEmpty {
            try staging.preflight(stagingByteLengths: remaining.map(\.byteLength),
                                  photoCopyByteLengths: objects.map(\.byteLength))
        }
        if job.captures[index].stage != .readyToSave {
            job.captures[index].stage = .downloading
            job = try await save(job)
        }

        for (frozen, current) in zip(job.captures[index].selection.descriptors, objects) {
            try checkRunning()
            guard let role = ImportOriginalRole(current.format) else { throw ImportStagingError.unsupportedFormat }
            let componentID = UUID()
            run?.componentID = componentID
            run?.componentBytes = 0
            defer { run?.componentID = nil }
            let progress: @Sendable (UInt64) async -> Void = { [weak self] bytes in
                await self?.publishProgress(
                    .init(role: role, receivedBytes: bytes, expectedBytes: current.byteLength), id: componentID)
            }
            if let previous = job.captures[index].originals.firstIndex(where: { $0.role == role }) {
                let original = try staging.reuse(job.captures[index].originals[previous], frozen: frozen, matching: current)
                if original.descriptor.sessionID == current.sessionID {
                    guard original.descriptor == current else { throw CameraImportError.freshSelectionRequired }
                    continue
                }
                let rebound = try await withCameraWork {
                    try await staging.rebind(original, to: current, session: session, progress: progress)
                }
                job.captures[index].originals[previous] = rebound
            } else {
                let original = try await withCameraWork {
                    try await staging.write(object: current, session: session, progress: progress)
                }
                job.captures[index].originals.append(original)
            }
            job = try await save(job)
        }
        try checkRunning()
        if job.captures[index].stage != .readyToSave {
            job.captures[index].stage = .validating
            job = try await save(job)
        }
        return job
    }

    private func withCameraWork<Value>(_ operation: () async throws -> Value) async throws -> Value {
        try checkRunning()
        run?.isUsingCamera = true
        defer { run?.isUsingCamera = false }
        do {
            return try await operation()
        } catch {
            // A failed sink or aborted transaction can close the channel even when
            // the surfaced failure is local storage. Require explicit readmission.
            retireSession()
            throw error
        }
    }

    private func retireSession() {
        if let sessionID = run?.sessionID { retiredSessions.insert(sessionID) }
        run?.invalidatedSession = true
        loan = nil
    }

    private struct SaveResult {
        let job: ImportJob
        var pauseReason: ImportPauseReason?
        var retryableSubmission = false
    }

    private func saveToPhotos(_ capture: ValidatedCapture, job: ImportJob, at index: Int) async throws -> SaveResult {
        var job = job
        let id = job.id
        let captureID = job.captures[index].id
        let fingerprints = capture.originals.map(\.fingerprint)
        let jobs = try await journal.loadJobs()
        let expected = Set(fingerprints)
        if jobs.contains(where: { candidate in
            candidate.captures.contains { entry in
                entry.stage.mayHaveSubmitted && Set(entry.originals.map(\.fingerprint)) == expected
            }
        }) {
            return .init(job: job, pauseReason: .unresolvedSave)
        }
        let existing = await recovery.lookup(fingerprints, jobs: jobs)
        try checkRunning()
        if let receipt = existing.receipt {
            let currentReceipt = ImportReceipt(captureID: captureID, fingerprints: fingerprints,
                                               assetID: receipt.assetID, verifiedAt: Date())
            try await journal.recordReceipt(currentReceipt, jobID: id, expectedRevision: job.revision)
            return .init(job: try await recovery.releaseCompletedFiles(recovery.load(id)))
        }
        if existing.status == .inaccessible { return .init(job: job, pauseReason: .photosAccess) }

        try staging.preflight(stagingByteLengths: [], photoCopyByteLengths: capture.originals.map(\.byteCount))
        job.captures[index].stage = .submitting
        job = try await save(job)
        if let requested = run?.requestedPause {
            let reopened = try await journal.reopenAfterProvenNoSave(jobID: id, captureID: captureID,
                expectedRevision: job.revision, evidence: .rejectedBeforeIssuance)
            return .init(job: reopened, pauseReason: requested)
        }

        let writer = journal.placeholderWriter
        let outcome = await gateway.create(capture) { assetID in
            try writer.persistPlaceholder(jobID: id, captureID: captureID, assetID: assetID)
        }
        if case .rejected(let failure) = outcome {
            let reopened = try await journal.reopenAfterProvenNoSave(jobID: id, captureID: captureID,
                expectedRevision: job.revision, evidence: .rejectedBeforeIssuance)
            return .init(job: reopened, pauseReason: Self.pauseReason(for: failure))
        }

        job = try await recovery.load(id)
        let observedID: String?
        switch outcome {
        case .submitted(let id): observedID = id
        case .uncertain(let id): observedID = id
        case .rejected: observedID = nil
        }
        if job.captures[index].placeholderAssetID == nil, let observedID {
            try await journal.recordPlaceholder(jobID: id, captureID: captureID, assetID: observedID)
            job = try await recovery.load(id)
        }
        run?.job = job
        run?.isVerifyingPhotos = true
        publish(job)
        defer { run?.isVerifyingPhotos = false }
        let (settled, result) = try await recovery.reconcile(job, at: index)
        if case .verified = result {
            run?.job = settled
            publish(settled)
            return .init(job: settled)
        }
        return .init(job: settled, pauseReason: .unresolvedSave, retryableSubmission: result == .definitivelyAbsent)
    }

    private func checkRunning() throws {
        try Task.checkCancellation()
        guard run?.requestedPause == nil else { throw CancellationError() }
    }

    private func save(_ job: ImportJob) async throws -> ImportJob {
        let saved = try await journal.save(job)
        run?.job = saved
        publish(saved)
        return saved
    }

    private func clearPause(_ job: ImportJob) async throws -> ImportJob {
        try await setPause(nil, on: job)
    }

    private func setPause(_ reason: ImportPauseReason?, on job: ImportJob) async throws -> ImportJob {
        guard job.pauseReason != reason else { return job }
        // Once fresh selection is required, lifecycle pauses must preserve that decision.
        guard job.pauseReason != .freshSelectionRequired || job.nextCaptureIndex == nil else { return job }
        var updated = job
        updated.pauseReason = reason
        return try await journal.save(updated)
    }

    private func publishProgress(_ component: ImportEvent.Component, id: UUID) {
        guard let run, run.requestedPause == nil, run.isUsingCamera, run.componentID == id,
              component.receivedBytes >= run.componentBytes, component.receivedBytes <= component.expectedBytes else { return }
        self.run?.componentBytes = component.receivedBytes
        publish(run.job, component: component)
    }

    private func publish(_ job: ImportJob, requestedPause: ImportPauseReason? = nil,
                         component: ImportEvent.Component? = nil, wirelessFailure: WirelessFailure? = nil,
                         retryableSubmission: Bool = false, runID: UUID? = nil, invalidatedSession: Bool = false,
                         routeEvidence: ImportRouteEvidence? = nil) {
        let active = run?.job.id == job.id
        let pause = requestedPause ?? (active ? run?.requestedPause : nil) ?? job.pauseReason
        let index = job.nextCaptureIndex
        let current = index.map { job.captures[$0] } ?? job.captures.last
        let needsSession = session(for: job.id) == nil
        var actions: ImportActions = []
        if active, pause == nil {
            actions = [.pause, .cancelRemaining]
        } else if !active, let current, !current.isFinished, pause != .journalUnavailable {
            if current.stage.mayHaveSubmitted {
                actions = [.managePhotos, .cancelRemaining]
                if retryableSubmission { actions.insert(.retryCapture) }
            } else {
                actions = [.skipCapture, .cancelRemaining, .discardRemaining]
                if pause != .freshSelectionRequired { actions.formUnion([.resume, .retryCapture]) }
                if pause == .photosAccess { actions.insert(.managePhotos) }
            }
        }
        sequence += 1
        let event = ImportEvent(sequence: sequence, jobID: job.id, runID: active ? run?.id : runID, cameraID: job.camera.cameraID,
            captureID: current?.id, captureIndex: index, captureCount: job.captures.count,
            stage: current?.stage, component: component, isVerifyingPhotos: active && run?.isVerifyingPhotos == true,
            isRunning: active, pauseReason: pause, actions: actions, needsSession: needsSession,
            invalidatedSession: invalidatedSession || (active && run?.invalidatedSession == true),
            wirelessFailure: wirelessFailure, receipts: job.captures.compactMap(\.receipt),
            routeEvidence: active ? run?.routeEvidence : routeEvidence,
            retainedBytes: job.retainedBytes, recoveryRequired: pause == .journalUnavailable)
        latest[job.id] = event
        if event.runID != nil { latestRunEvents[job.id] = event }
        for continuation in listeners.values { continuation.yield(event) }
    }

    private func publishJournalIssue() {
        sequence += 1
        let event = ImportEvent(sequence: sequence, jobID: nil, runID: nil, cameraID: nil, captureID: nil,
            captureIndex: nil, captureCount: 0, stage: nil, component: nil, isVerifyingPhotos: false,
            isRunning: false, pauseReason: .journalUnavailable, actions: [], needsSession: false, invalidatedSession: false,
            wirelessFailure: nil, receipts: [], routeEvidence: nil, retainedBytes: 0, recoveryRequired: true)
        journalIssue = event
        for continuation in listeners.values { continuation.yield(event) }
    }

    fileprivate static func requireSupported(_ identity: WirelessIdentity) throws {
        guard WirelessSupportPolicy().assess(model: identity.model.rawValue, firmware: identity.firmware)
            == .supported(identity.model) else { throw WirelessFailure.unsupportedFirmware }
    }

    private static func wirelessFailure(for error: any Error) -> WirelessFailure? {
        if let failure = error as? WirelessFailure { return failure }
        guard let ptp = error as? PTPError else { return nil }
        switch ptp {
        case .responseCode(0x2009): return .objectChanged
        case .responseCode(0x2008), .responseCode(0x2013): return .unavailableStorage
        case .timeout: return .timeout(.transactionInactivity)
        case .authorizationDenied: return .authentication
        default: return .connectionLost
        }
    }

    private static func pauseReason(for error: any Error) -> ImportPauseReason {
        if let posix = error as? POSIXError, posix.code == .ENOSPC || posix.code == .EDQUOT { return .storage }
        if (error as? CocoaError)?.code == .fileWriteOutOfSpace { return .storage }
        switch error {
        case WirelessFailure.objectChanged, WirelessFailure.unavailableStorage,
             CameraImportError.freshSelectionRequired, ImportStagingError.originalChanged:
            return .freshSelectionRequired
        case is WirelessFailure: return .connectionLost
        case ImportStagingError.insufficientCapacity, PhotoImportFailure.storage:
            return .storage
        case PhotoImportFailure.authorization: return .photosAccess
        case CameraImportError.unresolvedSave: return .unresolvedSave
        case is ImportJournalError: return .journalUnavailable
        default: return .captureFailed
        }
    }
}

private extension ImportJob {
    var nextCaptureIndex: Int? {
        captures.firstIndex { $0.stage.mayHaveSubmitted } ?? captures.firstIndex { !$0.isFinished }
    }

    var retainedBytes: UInt64 {
        captures.flatMap(\.originals).reduce(0) { total, original in total + original.byteCount }
    }
}

/// A unique fresh candidate and the same resolved pair are required before transfer.
/// Session IDs and handles route I/O only. Previously staged content is separately
/// rehashed against a newly bound camera session before joining it with another file.
private struct ImportInventory {
    let sessionID: UUID?
    let candidates: [CameraCaptureID: [WirelessObjectDescriptor]]
    let capturesByRaw: [WirelessObjectDescriptor: CameraCapture]
    let storage: WirelessStorageInventory

    static func read(_ session: any WirelessTransferSession, for snapshot: ImportCameraSnapshot) async throws -> Self {
        let camera = try await session.open()
        try CameraImportCoordinator.requireSupported(camera)
        let capabilities = try await session.capabilities()
        guard snapshot.matches(camera, mode: capabilities.mode) else { throw WirelessFailure.peerMismatch }
        let stream = try await session.enumerate()
        var inventory = WirelessStorageInventory(
            storage: Dictionary(capabilities.storageIDs.map { ($0, .pending) }, uniquingKeysWith: { first, _ in first }),
            rawExposure: capabilities.rawExposure)
        var cards: [UInt32: [UInt32: WirelessObjectDescriptor]] = [:]
        var sessionID: UUID?
        for try await batch in stream {
            try Task.checkCancellation()
            inventory.apply(batch)
            for object in batch.objects {
                guard object.cameraID == camera.cameraID,
                      sessionID == nil || sessionID == object.sessionID else { throw WirelessFailure.peerMismatch }
                sessionID = object.sessionID
                if let previous = cards[object.storageID]?[object.handle] {
                    guard previous == object else { throw WirelessFailure.objectChanged }
                    continue
                }
                guard (cards[object.storageID]?.count ?? 0) < WirelessPTPTransport.maximumObjectsPerStorage else {
                    throw WirelessFailure.malformedData
                }
                cards[object.storageID, default: [:]][object.handle] = object
            }
        }
        let updated = try await session.capabilities()
        guard updated.originalSizeVerified, updated.mode == capabilities.mode else {
            throw WirelessFailure.originalSizeUnavailable
        }
        let objects = cards.values.flatMap(\.values)
        let candidates = Dictionary(grouping: objects) { CameraCaptureID(describing: [$0]) }
        let captures = CaptureResolver.resolve(objects: objects, inventory: inventory)
        let byRaw = Dictionary(uniqueKeysWithValues: captures.compactMap { row in row.raw.map { ($0, row) } })
        return .init(sessionID: sessionID, candidates: candidates, capturesByRaw: byRaw, storage: inventory)
    }

    func match(_ selection: ImportSelection, requireOriginalRoutes: Bool) throws -> [WirelessObjectDescriptor] {
        let objects = try selection.descriptors.map { frozen in
            let matching = candidates[.init(describing: [frozen])] ?? []
            guard matching.count == 1, let candidate = matching.first, frozen.matchesOriginal(candidate),
                  storage.storage[candidate.storageID] == .complete,
                  !requireOriginalRoutes || candidate == frozen else { throw CameraImportError.freshSelectionRequired }
            return candidate
        }
        guard let raw = objects.first, let capture = capturesByRaw[raw] else {
            throw CameraImportError.freshSelectionRequired
        }
        switch selection.policy {
        case .pair:
            guard capture.availability == .pair, capture.objects == objects else {
                throw CameraImportError.freshSelectionRequired
            }
        case .rawOnly:
            guard capture.availability == .rawOnly || capture.availability == .ambiguous else {
                throw CameraImportError.freshSelectionRequired
            }
        }
        return objects
    }
}
