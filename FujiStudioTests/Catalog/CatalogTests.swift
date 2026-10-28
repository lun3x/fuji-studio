@testable import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

struct CatalogTests {
    @Test func editedPhoneRecipeRetainsPresetIdentityAcrossDurableRestart() async throws {
        let disk = try CatalogTestDisk(), f = try CatalogFixture(), profile = try ProductionProfileFixture()
        let catalog = try SwiftDataCatalog(storeURL: disk.url)
        let cameras = f.recipes()
        try await catalog.replaceRecipes(cameras)
        let original = try await catalog.copyRecipeToPhone(profile.bank)
        var draft = PhoneRecipeDraft(recipe: original); draft.name = "My Provia"
        draft.setValue(1, for: .film)
        let updated = try await catalog.updatePhoneRecipe(draft)
        #expect(updated.id == original.id)
        #expect(updated.snapshot.id != original.snapshot.id)
        #expect(try updated.snapshot.settings(using: RecipeCodecRegistry()).film == .provia)
        let reopened = try SwiftDataCatalog(storeURL: disk.url)
        #expect(try await reopened.phoneRecipes() == [updated])
        #expect(try await reopened.latestRecipes() == cameras)
        #expect(try await reopened.copyRecipeToPhone(profile.bank) == updated)
        #expect(try await reopened.updatePhoneRecipe(PhoneRecipeDraft(recipe: updated)) == updated)
    }

    @Test func staleOrDeletedDraftCannotOverwriteAnotherRevision() async throws {
        let disk = try CatalogTestDisk(), f = try CatalogFixture()
        let catalog = try SwiftDataCatalog(storeURL: disk.url)
        let original = try await catalog.copyRecipeToPhone(f.recipe)
        var first = PhoneRecipeDraft(recipe: original); first.name = "First edit"
        let updated = try await catalog.updatePhoneRecipe(first)
        var stale = PhoneRecipeDraft(recipe: original); stale.name = "Stale edit"
        await #expect(throws: PhoneRecipeEditingError.staleRecipe) { try await catalog.updatePhoneRecipe(stale) }
        try await catalog.deletePhoneRecipe(id: updated.id)
        await #expect(throws: PhoneRecipeEditingError.missingRecipe) { try await catalog.updatePhoneRecipe(PhoneRecipeDraft(recipe: updated)) }
        let recopied = try await catalog.copyRecipeToPhone(f.recipe)
        #expect(recopied.snapshot.id != original.snapshot.id)
        await #expect(throws: PhoneRecipeEditingError.staleRecipe) { try await catalog.updatePhoneRecipe(stale) }
        #expect(try await catalog.phoneRecipes() == [recopied])
    }

    @Test func deletingPhoneRecipeSurvivesRestartAndAllowsRecopy() async throws {
        let disk = try CatalogTestDisk(), f = try CatalogFixture()
        let catalog = try SwiftDataCatalog(storeURL: disk.url)
        let originals = f.recipes()
        try await catalog.replaceRecipes(originals)
        let copy = try await catalog.copyRecipeToPhone(originals[0])
        try await catalog.deletePhoneRecipe(id: copy.id)
        try await catalog.deletePhoneRecipe(id: copy.id)
        let reopened = try SwiftDataCatalog(storeURL: disk.url)
        #expect(try await reopened.phoneRecipes().isEmpty)
        #expect(try await reopened.latestRecipes() == originals)
        let recopied = try await reopened.copyRecipeToPhone(originals[0])
        #expect(recopied.snapshot.id != copy.snapshot.id)
        #expect(recopied.snapshot.importedSettings == copy.snapshot.importedSettings)
        #expect(try await reopened.phoneRecipes() == [recopied])
        try await reopened.deletePhoneRecipe(id: originals[1].id)
        #expect(try await reopened.phoneRecipes() == [recopied])
        #expect(try await reopened.latestRecipes() == originals)
    }

    @Test func deletingPhoneRecipePreservesFrozenExportHistory() async throws {
        let disk = try CatalogTestDisk(), f = try CatalogFixture()
        let catalog = try SwiftDataCatalog(storeURL: disk.url)
        let copy = try await catalog.copyRecipeToPhone(f.recipe)
        var job = f.job(recipe: copy.snapshot)
        let operationID = job.items[0].operationID
        job.items[0].state = .pendingSave(f.pending(operationID: operationID))
        let version = f.version(operationID: operationID, recipe: copy.snapshot)
        try await catalog.saveJob(job)
        try await catalog.deletePhoneRecipe(id: copy.id)
        #expect(try await catalog.job(id: job.id).recipeSnapshot == copy.snapshot)
        #expect(try await catalog.job(id: job.id).items == job.items)
        try await catalog.confirmSaved(jobID: job.id, operationID: operationID, version: version)
        let reopened = try SwiftDataCatalog(storeURL: disk.url)
        #expect(try await reopened.phoneRecipes().isEmpty)
        #expect(try await reopened.versions(sourceID: f.source.id) == [version])
        #expect(try await reopened.job(id: job.id).recipeSnapshot == copy.snapshot)
        #expect(try await reopened.job(id: job.id).items[0].state == .saved(version.id))
    }

    @Test func phoneCopyPreservesLosslessImportAcrossRestartAndCameraRefresh() async throws {
        let disk = try CatalogTestDisk(), f = try CatalogFixture()
        let original = f.recipe
        let catalog = try SwiftDataCatalog(storeURL: disk.url)
        let copy = try await catalog.copyRecipeToPhone(original)
        #expect(copy.snapshot.id != original.id)
        #expect(copy.snapshot.copiedFromRecipeID == original.id)
        #expect(copy.snapshot.isPhoneRecipe)
        #expect(copy.snapshot.name == original.name)
        #expect(copy.snapshot.slot == original.slot)
        #expect(copy.snapshot.importedName == original.importedName)
        #expect(copy.snapshot.importedSettings == original.importedSettings)
        #expect(copy.snapshot.settingsDigest == original.settingsDigest)
        #expect(copy.snapshot.cameraContext == original.cameraContext)
        #expect(copy.snapshot.importedAt == original.importedAt)
        #expect(copy.snapshot.renderingIssues == original.renderingIssues)
        #expect(copy.snapshot.renderingSupport(using: RecipeCodecRegistry()) == original.renderingSupport(using: RecipeCodecRegistry()))
        #expect(try await catalog.copyRecipeToPhone(original) == copy)
        let refreshed = f.recipes()
        try await catalog.replaceRecipes(refreshed)
        let reopened = try SwiftDataCatalog(storeURL: disk.url)
        #expect(try await reopened.phoneRecipes() == [copy])
        #expect(try await reopened.latestRecipes() == refreshed)
        #expect(try JSONDecoder().decode(RecipeSnapshot.self, from: JSONEncoder().encode(copy.snapshot)) == copy.snapshot)
    }

    @Test func phoneCopiesRemainDistinctWhenTheirCameraSlotIsReused() async throws {
        let disk = try CatalogTestDisk(), f = try CatalogFixture()
        let catalog = try SwiftDataCatalog(storeURL: disk.url)
        let a = try await catalog.copyRecipeToPhone(f.recipe)
        let b = try await catalog.copyRecipeToPhone(f.recipe(slot: 1, name: "New bank"))
        #expect(a.id != b.id)
        #expect(try await catalog.phoneRecipes().map(\.snapshot.name) == ["Synthetic bank", "New bank"])
        await #expect(throws: CatalogError.invalidRecipeCollection) {
            try await catalog.replaceRecipes([a.snapshot] + Array(f.recipes().dropFirst()))
        }
    }

    // Catches timestamp-based association, lost journal identity, and acknowledged-but-unsaved writes.
    @Test func restartPreservesDistinctSourcesWithEqualCaptureDates() async throws {
        let disk = try CatalogTestDisk()
        let f = try CatalogFixture()
        let originalOperationID = UUID()
        var job = f.job(operationID: originalOperationID)
        job.items[0].state = .pendingSave(f.pending(operationID: originalOperationID))
        let version = f.version(operationID: originalOperationID)
        do {
            let catalog: any CatalogStoring = try SwiftDataCatalog(storeURL: disk.url)
            try await catalog.upsertSources([f.source, f.sourceB])
            try await catalog.saveJob(job)
            try await catalog.confirmSaved(jobID: job.id, operationID: originalOperationID, version: version)
        }
        let reopened: any CatalogStoring = try SwiftDataCatalog(storeURL: disk.url)
        let reopenedVersionsForA = try await reopened.versions(sourceID: "A")
        let reopenedVersionsForB = try await reopened.versions(sourceID: "B")
        let reopenedJob = try await reopened.job(id: job.id)
        #expect(reopenedVersionsForA.map(\.sourceID) == ["A"])
        #expect(reopenedVersionsForB.isEmpty)
        #expect(reopenedJob.items.first?.operationID == originalOperationID)
        #expect(reopenedJob.items.first?.state == .saved(version.id))
        #expect(try await reopened.unfinishedJobs().isEmpty)
    }

    // Catches replacing the visible collection with a partial, duplicate-slot or mixed-session refresh.
    @Test func partialRecipeRefreshCannotReplaceCollection() async throws {
        let disk = try CatalogTestDisk()
        let f = try CatalogFixture()
        let previous = f.recipes()
        do {
            let catalog = try SwiftDataCatalog(storeURL: disk.url)
            try await catalog.replaceRecipes(previous)
            for invalid in [Array(f.recipes().prefix(6)), Array(repeating: f.recipe, count: 7),
                            Array(f.recipes().prefix(6)) + [f.recipe(slot: 7, context: .init(
                                model: "X-T5", firmware: "synthetic", capability: "synthetic",
                                sessionIdentity: UUID(), sessionGeneration: 1))]] {
                await #expect(throws: CatalogError.invalidRecipeCollection) {
                    try await catalog.replaceRecipes(invalid)
                }
            }
        }
        let reopened = try SwiftDataCatalog(storeURL: disk.url)
        let visibleRecipes = try await reopened.latestRecipes()
        #expect(visibleRecipes.count == 7)
        #expect(visibleRecipes.map(\.id) == previous.map(\.id))
    }

    // Catches refreshing mutable slots in place, rejection of unsupported but lossless imports,
    // and matching a different session/generation when returning camera-specific recipes.
    @Test func successfulRefreshRetainsFrozenHistoryAndOfflineCollection() async throws {
        let disk = try CatalogTestDisk()
        let f = try CatalogFixture()
        let previous = f.recipes()
        var job = f.job(recipe: previous[0])
        let pending = f.pending(operationID: job.items[0].operationID)
        job.items[0].state = .pendingSave(pending)
        let version = f.version(operationID: job.items[0].operationID, recipe: previous[0])
        let refreshed = f.recipes()
        do {
            let catalog = try SwiftDataCatalog(storeURL: disk.url)
            try await catalog.replaceRecipes(previous)
            try await catalog.saveJob(job)
            try await catalog.confirmSaved(jobID: job.id, operationID: version.operationID, version: version)
            try await catalog.replaceRecipes(refreshed)
            // A library refresh must not alter an already submitted source/resource/date/location.
            try await catalog.upsertSources([f.changedSource])
        }
        let reopened = try SwiftDataCatalog(storeURL: disk.url)
        #expect(try await reopened.latestRecipes() == refreshed)
        #expect(try await reopened.recipes(camera: f.camera) == refreshed)
        let other = CameraExecutionContext(model: f.camera.model, firmware: f.camera.firmware,
            capability: f.camera.capability, supportVersion: f.camera.supportVersion,
            sessionIdentity: UUID(), generation: f.camera.generation)
        #expect(try await reopened.recipes(camera: other).isEmpty)
        let next = CameraExecutionContext(model: f.camera.model, firmware: f.camera.firmware,
            capability: f.camera.capability, supportVersion: f.camera.supportVersion,
            sessionIdentity: f.camera.sessionIdentity, generation: 2)
        #expect(try await reopened.recipes(camera: next).isEmpty)
        #expect(try await reopened.job(id: job.id).items[0].source == f.source)
        #expect(try await reopened.job(id: job.id).recipeSnapshot == previous[0])
        #expect(try await reopened.versions(sourceID: "A").first?.recipeSnapshot == previous[0])
        #expect(refreshed.allSatisfy { !$0.importedSettings.isEmpty && !$0.renderingIssues.isEmpty })
    }

    // Catches a failed write leaking staged snapshots or an updated active collection.
    @Test func failedRefreshRollsBackEveryStagedSnapshot() async throws {
        let disk = try CatalogTestDisk()
        let f = try CatalogFixture()
        let previous = f.recipes()
        var candidate = f.recipes()
        candidate[6] = f.recipe(slot: 7, id: previous[6].id, name: "conflicting immutable bytes")
        do {
            let catalog = try SwiftDataCatalog(storeURL: disk.url)
            try await catalog.replaceRecipes(previous)
            await #expect(throws: CatalogError.conflictingSnapshot(previous[6].id)) {
                try await catalog.replaceRecipes(candidate)
            }
            #expect(try await catalog.latestRecipes() == previous)
        }
        let reopened = try SwiftDataCatalog(storeURL: disk.url)
        #expect(try await reopened.latestRecipes() == previous)
        // Reuse an ID from earlier in the aborted transaction with different data. If that
        // staged record leaked despite rollback this valid new collection would conflict.
        var clean = f.recipes()
        clean[0] = f.recipe(slot: 1, id: candidate[0].id, name: "after rollback")
        try await reopened.replaceRecipes(clean)
        #expect(try await reopened.latestRecipes() == clean)
    }

    // Catches lost uncertainty/placeholder information or conflating a render attempt with a save.
    @Test func pendingSavePhasesAndOrderedSubmissionSurviveRestart() async throws {
        let disk = try CatalogTestDisk()
        let f = try CatalogFixture()
        let phases: [SaveSubmission] = [.notSubmitted, .submitted(at: f.exportTime),
            .unknown(at: f.exportTime), .definitivelyRejected(at: f.exportTime, reason: "synthetic denial")]
        var expected: [ExportJob] = []
        do {
            let catalog = try SwiftDataCatalog(storeURL: disk.url)
            for phase in phases {
                var job = f.job()
                job.items.append(ExportItem(source: f.sourceB, operationID: UUID(), state: .unprocessed))
                var pending = f.pending(operationID: job.items[0].operationID)
                pending.placeholderID = "synthetic-placeholder"
                pending.submission = phase
                job.items[0].state = .pendingSave(pending)
                job.state = .pendingSave
                try await catalog.saveJob(job)
                expected.append(job)
            }
        }
        let reopened = try SwiftDataCatalog(storeURL: disk.url)
        #expect(try await reopened.unfinishedJobs().count == 4)
        for job in expected {
            let actual = try await reopened.job(id: job.id)
            #expect(actual == job)
            #expect(actual.items.map(\.source.id) == ["A", "B"])
            if case .pendingSave(let pending) = actual.items[0].state {
                #expect(pending.filename == "FujiStudio-\(actual.items[0].operationID.uuidString).jpg")
                #expect(pending.operationID != pending.jpeg.operationID)
                #expect(pending.jpeg.outputSHA256 == "synthetic-output")
                #expect(pending.jpeg.key.sourceRevision == "original-revision")
            } else { Issue.record("Pending save was lost") }
        }
    }

    // Catches duplicate records for retries and accidental deduplication of deliberate exports.
    @Test func confirmationIsIdempotentButDeliberateRepeatCreatesAnotherVersion() async throws {
        let disk = try CatalogTestDisk()
        let f = try CatalogFixture()
        let catalog = try SwiftDataCatalog(storeURL: disk.url)
        var expected: Set<UUID> = []
        for _ in 0..<2 {
            var job = f.job()
            let operation = job.items[0].operationID
            job.items[0].state = .pendingSave(f.pending(operationID: operation))
            let version = f.version(operationID: operation)
            try await catalog.saveJob(job)
            try await catalog.confirmSaved(jobID: job.id, operationID: operation, version: version)
            try await catalog.confirmSaved(jobID: job.id, operationID: operation, version: version)
            // Recovery may reconstruct a DTO with a new version UUID; the save operation
            // retains the first canonical version rather than minting another history row.
            try await catalog.confirmSaved(jobID: job.id, operationID: operation,
                version: f.version(operationID: operation))
            expected.insert(version.id)
        }
        let reopened = try SwiftDataCatalog(storeURL: disk.url)
        #expect(Set(try await reopened.versions(sourceID: "A").map(\.id)) == expected)
        #expect(try await reopened.versions(sourceID: "A").count == 2)
    }

    // Catches overwriting the operation's canonical output or acknowledging half a confirmation.
    @Test func conflictingConfirmationLeavesVersionAndJournalUnchanged() async throws {
        let disk = try CatalogTestDisk()
        let f = try CatalogFixture()
        let catalog = try SwiftDataCatalog(storeURL: disk.url)
        var job = f.job()
        let operation = job.items[0].operationID
        job.items[0].state = .pendingSave(f.pending(operationID: operation))
        try await catalog.saveJob(job)
        let bad = f.version(operationID: operation, sourceID: "B")
        await #expect(throws: CatalogError.conflictingOperation(operation)) {
            try await catalog.confirmSaved(jobID: job.id, operationID: operation, version: bad)
        }
        #expect(try await catalog.versions(sourceID: "A").isEmpty)
        #expect(try await catalog.job(id: job.id) == job)
        let version = f.version(operationID: operation)
        try await catalog.confirmSaved(jobID: job.id, operationID: operation, version: version)
        let conflict = f.version(operationID: operation, outputAssetID: "different-output")
        await #expect(throws: CatalogError.conflictingOperation(operation)) {
            try await catalog.confirmSaved(jobID: job.id, operationID: operation, version: conflict)
        }
        let reopened = try SwiftDataCatalog(storeURL: disk.url)
        #expect(try await reopened.versions(sourceID: "A") == [version])
        #expect(try await reopened.job(id: job.id).items[0].state == .saved(version.id))
    }

    // Catches first confirmation replacing an already known Photos asset with another output.
    @Test func firstConfirmationMustMatchKnownPlaceholderAfterRestart() async throws {
        let f = try CatalogFixture()
        for submission in [SaveSubmission.submitted(at: f.exportTime), .unknown(at: f.exportTime)] {
            let disk = try CatalogTestDisk()
            var job = f.job()
            let operation = job.items[0].operationID
            let pending = PendingSave(operationID: operation, jpeg: f.jpeg(),
                placeholderID: "asset-A", submission: submission)
            if case .unknown = submission { job.items[0].state = .unresolved(pending) }
            else { job.items[0].state = .pendingSave(pending) }
            do {
                let catalog = try SwiftDataCatalog(storeURL: disk.url)
                try await catalog.saveJob(job)
            }
            do {
                let reopened = try SwiftDataCatalog(storeURL: disk.url)
                let wrong = f.version(operationID: operation, outputAssetID: "asset-B")
                await #expect(throws: CatalogError.conflictingOperation(operation)) {
                    try await reopened.confirmSaved(jobID: job.id, operationID: operation, version: wrong)
                }
            }
            let reopened = try SwiftDataCatalog(storeURL: disk.url)
            #expect(try await reopened.job(id: job.id) == job)
            #expect(try await reopened.versions(sourceID: "A").isEmpty)
            let correct = f.version(operationID: operation, outputAssetID: "asset-A")
            try await reopened.confirmSaved(jobID: job.id, operationID: operation, version: correct)
            let confirmed = try SwiftDataCatalog(storeURL: disk.url)
            #expect(try await confirmed.versions(sourceID: "A") == [correct])
            #expect(try await confirmed.job(id: job.id).items[0].state == .saved(correct.id))
        }
    }

    // Catches treating an unsubmitted/rejected item as a source/output conflict or a saved asset.
    @Test func confirmationRequiresDurableSubmittedAttempt() async throws {
        let disk = try CatalogTestDisk()
        let f = try CatalogFixture()
        let catalog = try SwiftDataCatalog(storeURL: disk.url)
        for submission: SaveSubmission? in [nil, .notSubmitted, .definitivelyRejected(at: f.exportTime, reason: "synthetic")] {
            var job = f.job()
            let operation = job.items[0].operationID
            if let submission {
                job.items[0].state = .pendingSave(.init(operationID: operation, jpeg: f.jpeg(),
                    placeholderID: nil, submission: submission))
            }
            try await catalog.saveJob(job)
            do {
                try await catalog.confirmSaved(jobID: job.id, operationID: operation, version: f.version(operationID: operation))
                Issue.record("An unsubmitted or rejected save was confirmed")
            } catch CatalogError.invalidState(_) {
                // The journal needs a submitted attempt before confirmation is meaningful.
            } catch { Issue.record("Expected invalidState, received \(error)") }
            #expect(try await catalog.versions(sourceID: "A").isEmpty)
            #expect(try await catalog.job(id: job.id) == job)
        }
    }

    // Catches mutation of submitted identity, save states bypassing atomic confirmation,
    // and reuse of one Photos operation across jobs.
    @Test func journalRejectsChangedSubmissionAndReusedOperations() async throws {
        let disk = try CatalogTestDisk()
        let f = try CatalogFixture()
        let catalog = try SwiftDataCatalog(storeURL: disk.url)
        let job = f.job()
        try await catalog.saveJob(job)
        let changed = ExportJob(id: job.id, submittedAt: job.submittedAt, recipeSnapshot: f.recipe,
            items: [ExportItem(source: f.changedSource, operationID: job.items[0].operationID)], state: .queued)
        await #expect(throws: CatalogError.self) { try await catalog.saveJob(changed) }
        let reused = f.job(operationID: job.items[0].operationID)
        await #expect(throws: CatalogError.conflictingOperation(job.items[0].operationID)) {
            try await catalog.saveJob(reused)
        }
        var forged = job
        forged.items[0].state = .saved(UUID())
        await #expect(throws: CatalogError.self) { try await catalog.saveJob(forged) }
        #expect(try await catalog.job(id: job.id) == job)
        await #expect(throws: CatalogError.missingJob(reused.id)) { try await catalog.job(id: reused.id) }
    }

    // Catches a restart/retry discarding an uncertain system transaction and permitting duplicate saves.
    @Test func uncertainSaveKeepsPinnedAttemptUntilDefinitiveRejection() async throws {
        let disk = try CatalogTestDisk()
        let f = try CatalogFixture()
        var job = f.job()
        let operation = job.items[0].operationID
        var pending = f.pending(operationID: operation)
        job.items[0].state = .pendingSave(pending)
        do {
            let catalog = try SwiftDataCatalog(storeURL: disk.url)
            try await catalog.saveJob(job)
            pending.placeholderID = "known-placeholder"
            job.items[0].state = .pendingSave(pending)
            try await catalog.saveJob(job)
        }
        let reopened = try SwiftDataCatalog(storeURL: disk.url)
        let invalidStates: [ExportItemState] = [.queued, .preparing, .converting, .failed(.authorization),
            .cancelled, .unprocessed,
            .pendingSave(.init(operationID: operation, jpeg: f.jpeg(), placeholderID: "known-placeholder", submission: .notSubmitted)),
            .pendingSave(.init(operationID: operation, jpeg: f.jpeg(), placeholderID: nil, submission: .unknown(at: f.exportTime))),
            .pendingSave(.init(operationID: operation, jpeg: f.jpeg(), placeholderID: "changed-placeholder", submission: .unknown(at: f.exportTime))),
            .pendingSave(.init(operationID: operation, jpeg: f.jpeg(), placeholderID: "known-placeholder", submission: .unknown(at: f.exportTime.addingTimeInterval(1)))),
            .pendingSave(.init(operationID: operation, jpeg: f.jpeg(fileURL: URL(fileURLWithPath: "/synthetic/replacement.jpg")),
                placeholderID: "known-placeholder", submission: .unknown(at: f.exportTime)))]
        for state in invalidStates {
            var changed = job
            changed.items[0].state = state
            await #expect(throws: CatalogError.self) { try await reopened.saveJob(changed) }
            #expect(try await reopened.job(id: job.id) == job)
        }
        pending.submission = .unknown(at: f.exportTime)
        job.items[0].state = .unresolved(pending)
        try await reopened.saveJob(job)
        #expect(try await reopened.unfinishedJobs().map(\.id) == [job.id])
        pending.submission = .definitivelyRejected(at: f.exportTime, reason: "synthetic system rejection")
        job.items[0].state = .pendingSave(pending)
        try await reopened.saveJob(job)
        // Only actual rejection permits Task8 to reset/retry the same deliberate operation.
        job.items[0].state = .queued
        try await reopened.saveJob(job)
        let again = try SwiftDataCatalog(storeURL: disk.url)
        #expect(try await again.job(id: job.id) == job)
        var recovered = f.job()
        var uncertain = f.pending(operationID: recovered.items[0].operationID)
        uncertain.submission = .unknown(at: f.exportTime)
        recovered.items[0].state = .unresolved(uncertain)
        try await again.saveJob(recovered)
        let version = f.version(operationID: recovered.items[0].operationID)
        try await again.confirmSaved(jobID: recovered.id, operationID: version.operationID, version: version)
        #expect(try await again.job(id: recovered.id).items[0].state == .saved(version.id))
    }

    // Catches destructive reconciliation and a stale idempotent confirmation restoring availability.
    @Test func inaccessibleAndDeletedAssetsRetainDurableHistory() async throws {
        let disk = try CatalogTestDisk()
        let f = try CatalogFixture()
        var job = f.job()
        let operation = job.items[0].operationID
        job.items[0].state = .pendingSave(f.pending(operationID: operation))
        let version = f.version(operationID: operation)
        do {
            let catalog = try SwiftDataCatalog(storeURL: disk.url)
            try await catalog.saveJob(job)
            try await catalog.confirmSaved(jobID: job.id, operationID: operation, version: version)
            try await catalog.setAvailability(assetID: version.outputAssetID, availability: .inaccessible)
            try await catalog.setAvailability(assetID: "A", availability: .deleted)
            try await catalog.confirmSaved(jobID: job.id, operationID: operation, version: version)
        }
        let reopened = try SwiftDataCatalog(storeURL: disk.url)
        let versions = try await reopened.versions(sourceID: "A")
        #expect(versions.count == 1)
        let retained = try #require(versions.first)
        #expect(retained.id == version.id)
        #expect(retained.availability == .inaccessible)
        #expect(try await reopened.job(id: job.id).items[0].source == f.source)
    }
}

private struct CatalogTestDisk {
    let directory: URL
    var url: URL { directory.appendingPathComponent("catalog.store") }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    // Retain this real disk store for test-process/OS cleanup. Reopened SwiftData
    // containers can still own open file descriptors when the test body returns.
}

private struct CatalogFixture {
    let recipeID = UUID()
    let camera = CameraExecutionContext(model: "X-T5", firmware: "synthetic", capability: "synthetic",
        supportVersion: "synthetic", sessionIdentity: UUID(), generation: 1)
    let exportTime = Date(timeIntervalSince1970: 2_000)
    let profile: ProductionProfileFixture
    init() throws { profile = try ProductionProfileFixture() }
    var recipe: RecipeSnapshot { recipe(slot: 1, id: recipeID) }
    func recipe(slot: Int, id: UUID = UUID(), name: String = "Synthetic bank", context: RecipeCameraContext? = nil) -> RecipeSnapshot {
        RecipeSnapshot(id: id, slot: slot, name: name, importedName: Data([2, 65, 0, 0, 0]),
            importedSettings: [.init(code: 0xFFFF, raw: Data([0xBE, 0xEF]))], settingsDigest: "synthetic-digest",
            cameraContext: context ?? .init(model: camera.model, firmware: camera.firmware,
                capability: camera.capability, sessionIdentity: camera.sessionIdentity, sessionGeneration: camera.generation),
            importedAt: Date(timeIntervalSince1970: 1_000), renderingIssues: [.unmappedProperty(0xFFFF)])
    }
    func recipes() -> [RecipeSnapshot] { (1...7).map { recipe(slot: $0) } }
    var source: PhotoSource { source(id: "A") }
    var sourceB: PhotoSource { source(id: "B") }
    var changedSource: PhotoSource { PhotoSource(id: "A", originalResources: source.originalResources,
        captureDate: Date(timeIntervalSince1970: 9_000), location: nil, resourceRevision: "changed", compatibility: .supported(model: "X-T5")) }
    func source(id: String) -> PhotoSource {
        PhotoSource(id: id, originalResources: .init(raf: .init(assetID: id, role: .primaryOriginal,
            contentTypeIdentifier: "com.fujifilm.raw-image", format: .raf, originalFilename: "SYNTHETIC.RAF",
            discriminator: "synthetic-raf", sourceRevision: "original-revision", byteCount: 100),
            jpeg: id == "A" ? .init(assetID: id, role: .alternateOriginal, contentTypeIdentifier: "public.jpeg",
                format: .jpeg, originalFilename: "SYNTHETIC.JPG", discriminator: "synthetic-jpeg",
                sourceRevision: "original-revision", byteCount: 50) : nil),
            captureDate: Date(timeIntervalSince1970: 100), location: .init(latitude: 1, longitude: 2, altitude: 3),
            resourceRevision: "original-revision", compatibility: .supported(model: "X-T5"))
    }
    func job(operationID: UUID = UUID(), recipe: RecipeSnapshot? = nil) -> ExportJob {
        ExportJob(id: UUID(), submittedAt: Date(timeIntervalSince1970: 1_500), recipeSnapshot: recipe ?? self.recipe,
            items: [ExportItem(source: source, operationID: operationID)], state: .queued)
    }
    func jpeg(fileURL: URL = URL(fileURLWithPath: "/synthetic/pinned.jpg")) -> CameraJPEG {
        let key = RenderKey(sourceID: "A", sourceRevision: "original-revision", sourceSHA256: "synthetic-raw",
            settingsDigest: "synthetic-digest", cameraContext: camera, width: 7728, height: 5152, orientation: 8,
            policy: .fullSizeFineRecordedGeometry, quality: .fullResolutionFine)
        return CameraJPEG(fileURL: fileURL, sourceID: "A",
            sourceRevision: "original-revision", sourceSHA256: "synthetic-raw", recipeSnapshotID: profile.bank.id,
            settingsDigest: "synthetic-digest", cameraContext: camera, operationID: camera.sessionIdentity,
            width: 7728, height: 5152, orientation: 8, quality: .fullResolutionFine,
            effectiveRecipe: .init(supportVersion: "synthetic", requested: try! profile.bank.settings(using: RecipeCodecRegistry()),
                dormantGrainSizeNotSerialized: false, inactiveKelvinPreserved: false,
                lensOptimizerRequested: true, lensOptimizerEffective: false, lensOptimizerAdjusted: true, evidence: "synthetic"),
            baselineSHA256: "synthetic-baseline", candidateSHA256: "synthetic-candidate", outputSHA256: "synthetic-output", key: key)
    }
    func pending(operationID: UUID) -> PendingSave {
        PendingSave(operationID: operationID, jpeg: jpeg(), placeholderID: nil, submission: .submitted(at: exportTime))
    }
    func version(operationID: UUID, sourceID: String = "A", outputAssetID: String = "synthetic-output-asset",
                 recipe: RecipeSnapshot? = nil) -> SavedVersion {
        SavedVersion(id: UUID(), sourceID: sourceID, outputAssetID: outputAssetID,
            recipeSnapshot: recipe ?? self.recipe, operationID: operationID, exportedAt: exportTime,
            jpeg: jpeg(), availability: .available)
    }
}
