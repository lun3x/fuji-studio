#if DEBUG
import Foundation
import Observation
import Photos
import ImageIO

private enum LiveAcceptanceFailure: Error { case stopped(String) }

/// Small opt-in instrumentation over the ONE live model and its services. It has no writer,
/// camera factory, replacement catalog, resume action, or fallback source selection.
@MainActor @Observable final class LiveAcceptanceRunner {
    struct Receipt: Codable {
        let runID: UUID
        var jobID: UUID?
        var exportArmed = false
    }
    struct Expected: Codable {
        let sourceA: PhotoSource, sourceB: PhotoSource
        let originalHashes: [String: String]
        let preview: CameraJPEG
        let recipe: RecipeSnapshot
        let precedingVersions: [SavedVersion]
        let precedingAssetIDs: Set<String>
    }
    struct Evidence: Codable {
        var stage = "claimed"
        var previewCount = 0
        var originalDefaultsVerified = false, banksPreserved = false, previewPhotoCountUnchanged = false
        var singleViewedExport = false, exactSavedBytes = false, distinctAsset = false
        var captureDatePreserved = false, locationPreserved = false, originalsUnchanged = false
        var catalogAssociation = false, reopened = false, complete = false
        var nativeCloseConfirmed = false
        var width: Int?, height: Int?, orientation: Int?
        var failure: String?
    }
    private(set) var status = "Live validation not started"
    private var didRun = false

    func run(model: AppModel, id: UUID, documents requested: URL? = nil) async {
        guard !didRun else { return }; didRun = true
        var evidence = Evidence()
        var run: LiveAcceptanceRun?
        do {
            let documents = try requested ?? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let claim = LiveAcceptanceRun(root: documents.appendingPathComponent("live-acceptance-private/runs"), id: id)
            run = claim
            guard try claim.claim() else {
                // No export or conversion on any replay, even when no real job ID was recorded.
                let receipt = try claim.read(Receipt.self, name: "receipt.json")
                guard receipt.runID == id, receipt.exportArmed, let jobID = receipt.jobID else {
                    throw LiveAcceptanceFailure.stopped("Existing run has no recorded job; outcome unknown, no automatic retry")
                }
                evidence = try claim.read(Evidence.self, name: "evidence.json")
                evidence.complete = false; evidence.reopened = true
                await model.reconcile()
                let expected = try claim.read(Expected.self, name: "expected.json")
                try await verify(model: model, jobID: jobID, expected: expected, run: claim, evidence: &evidence)
                evidence.complete = evidence.originalDefaultsVerified && evidence.previewCount == 7 && evidence.banksPreserved
                    && evidence.previewPhotoCountUnchanged && evidence.singleViewedExport && evidence.nativeCloseConfirmed
                evidence.stage = evidence.complete ? "reopened exact saved version; no export replay" : "saved version verified read-only; original run remains incomplete"
                try publish(evidence, run: claim)
                return
            }
            var receipt = Receipt(runID: id)
            try claim.write(receipt, name: "receipt.json")
            try publish(evidence, run: claim)
            guard model.state.libraryAccess == .full, !model.isSuspended, model.state.activeJobID == nil,
                  try await model.environment.catalog.unfinishedJobs().isEmpty else {
                throw LiveAcceptanceFailure.stopped("Full access, foreground and no unfinished jobs required")
            }
            // Strict retained source uniqueness and RAF metadata/hash checks run off the UI actor.
            let inputs = try await RetainedProductionAcceptanceInputs.prepare(documents: documents, destination: claim.directory)
            let bindings = try await Task.detached {
                (try RetainedProductionAcceptanceInputs.loadSource(root: documents.appendingPathComponent("xt5-raw-baseline-private"), paired: false),
                 try RetainedProductionAcceptanceInputs.loadSource(root: documents.appendingPathComponent("xt5-paired-baseline-private"), paired: true))
            }.value
            let a = try await model.environment.reader.source(id: inputs.a.sourceID)
            let b = try await model.environment.reader.source(id: inputs.b.sourceID)
            try Self.validate(source: a, retained: bindings.0, paired: false)
            try Self.validate(source: b, retained: bindings.1, paired: true)
            guard a.id != b.id, inputs.a.sha256 != inputs.b.sha256, b.captureDate != nil,
                  model.sources.filter({ $0 == a }).count == 1, model.sources.filter({ $0 == b }).count == 1 else {
                throw LiveAcceptanceFailure.stopped("Retained originals do not uniquely match the current library")
            }
            let hashes = try await originalHashes(model: model, a: a, b: b)
            guard hashes["A-RAF"] == inputs.a.sha256, hashes["B-RAF"] == inputs.b.sha256 else { throw ResourceError.checksumMismatch }
            let originalAssetIDs = Self.assetIDs()
            model.send(.recipeSelected(slot: nil)); model.send(.sourceTapped(a.id))
            try await wait(model) { model.state.displayedVersion == .raw && model.displayFile != nil && model.imageStatus == nil }
            guard !model.state.canExport, let rawDisplay = model.displayFile else { throw LiveAcceptanceFailure.stopped("No-recipe RAW default missing") }
            try FileManager.default.copyItem(at: rawDisplay.fileURL, to: claim.directory.appendingPathComponent("A-original-display.JPG"))
            model.send(.sourceTapped(b.id))
            try await wait(model) { model.state.displayedVersion == .cameraJPEG && model.displayFile != nil && model.imageStatus == nil }
            guard !model.state.canExport, let jpegDisplay = model.displayFile,
                  try await checksum(jpegDisplay.fileURL) == hashes["B-JPEG"] else { throw ResourceError.checksumMismatch }
            evidence.originalDefaultsVerified = true; evidence.stage = "connecting and importing seven current banks"
            try publish(evidence, run: claim)
            await model.connect()
            try await wait(model) { !model.isRefreshing && model.state.currentCameraExecutionContext != nil && model.state.recipes.count == 7 }
            let banks = model.state.recipes
            guard Self.banksMatch(state: model.state, retained: inputs.banks) else { throw CameraServiceError.unsupportedSettings }
            try claim.write(banks, name: "banks-before.json")
            // No recipe is selected while switching to A; each explicit slot intent completes
            // before the next. These use PreviewCoordinator, never any Photos save interface.
            model.send(.sourceTapped(a.id))
            for slot in 1...7 {
                let recipe = try recipe(slot, banks: banks)
                model.send(.recipeSelected(slot: slot))
                let (jpeg, lease) = try await preview(model, source: a, recipe: recipe, hash: inputs.a.sha256)
                try retain(jpeg, lease: lease, stem: "A-C\(slot)", run: claim)
                evidence.previewCount += 1; evidence.stage = "temporary A previews complete: \(slot)/7"
                try publish(evidence, run: claim)
            }
            guard Self.assetIDs() == originalAssetIDs else {
                throw LiveAcceptanceFailure.stopped("Photos library changed during previews; observation ambiguous")
            }
            evidence.previewPhotoCountUnchanged = true
            model.send(.recipeSelected(slot: nil)); model.send(.sourceTapped(b.id))
            try await wait(model) { model.state.displayedVersion == .cameraJPEG && model.displayFile != nil }
            let chosen = try recipe(7, banks: banks)
            model.send(.recipeSelected(slot: 7))
            let (jpeg, heldLease) = try await preview(model, source: b, recipe: chosen, hash: inputs.b.sha256)
            guard Self.assetIDs() == originalAssetIDs else { throw LiveAcceptanceFailure.stopped("Photos library changed before export; observation ambiguous") }
            try retain(jpeg, lease: heldLease, stem: "B-C7", run: claim)
            guard !model.state.isSelecting, model.state.effectiveSources == [b], model.state.canExport,
                  model.state.selectedRecipe == chosen else { throw LiveAcceptanceFailure.stopped("Viewed-source export precondition changed") }
            let expected = Expected(sourceA: a, sourceB: b, originalHashes: hashes, preview: jpeg, recipe: chosen,
                precedingVersions: try await model.environment.catalog.versions(sourceID: b.id), precedingAssetIDs: originalAssetIDs)
            try claim.write(expected, name: "expected.json")
            let priorJobs = Set(model.progressEvents.map(\.jobID))
            // This durable intent is written BEFORE calling the sole real AppModel export path.
            // A process death anywhere beyond this line consumes the run, including before ID return.
            receipt.exportArmed = true
            try claim.write(receipt, name: "receipt.json")
            evidence.stage = "one explicit C7 viewed-source export intent persisted"
            try publish(evidence, run: claim)
            await model.export()
            try await wait(model) { model.exportEvent.map { !priorJobs.contains($0.jobID) } == true }
            guard let jobID = model.exportEvent?.jobID else { throw LiveAcceptanceFailure.stopped("No real export job identity returned") }
            receipt.jobID = jobID; try claim.write(receipt, name: "receipt.json")
            evidence.singleViewedExport = true; evidence.stage = "one real export job admitted"
            try publish(evidence, run: claim)
            try await wait(model) { model.exportEvent?.jobID == jobID && model.exportEvent?.terminal == true }
            // Keep the actual preview lease alive across export, unpin and byte comparison.
            try await verify(model: model, jobID: jobID, expected: expected, run: claim, evidence: &evidence)
            guard try await checksum(heldLease.fileURL) == jpeg.outputSHA256 else { throw ResourceError.checksumMismatch }
            withExtendedLifetime(heldLease) {}
            await model.refreshRecipes()
            guard XT5FiniteRecipePatch.sameBanks(banks, model.state.recipes), Self.banksMatch(state: model.state, retained: inputs.banks) else {
                throw CameraServiceError.ownershipChanged
            }
            try claim.write(model.state.recipes, name: "banks-after.json")
            evidence.banksPreserved = true
            evidence.stage = "one save verified; relaunch same UUID for read-only reopen proof"
            await model.environment.camera.disconnect()
            try await wait(model) { model.state.cameraState == .disconnected }
            evidence.nativeCloseConfirmed = true; evidence.complete = true
            try publish(evidence, run: claim)
        } catch {
            evidence.complete = false
            if case LiveAcceptanceFailure.stopped(let reason) = error { evidence.failure = reason }
            else { evidence.failure = "Validation stopped; inspect private evidence; no automatic retry" }
            evidence.stage = "stopped"
            // Real active operations own their drain/reconciliation; no cancellation or replacement save.
            if let run {
                try? run.write(["error": String(reflecting: error), "imageStatus": model.imageStatus ?? "",
                    "modelMessage": model.message ?? "", "cameraState": String(reflecting: model.state.cameraState)], name: "failure-private.json")
                try? publish(evidence, run: run)
            }
            status = evidence.failure ?? "Validation stopped"
        }
    }

    static func banksMatch(state: WorkspaceState, retained: [RecipeSnapshot]) -> Bool {
        guard state.recipeRefreshState == .fresh, let context = state.currentCameraExecutionContext,
              XT5FiniteRecipePatch.sameBanks(state.recipes, retained) else { return false }
        return state.recipes.allSatisfy { recipe in
            recipe.cameraContext.sessionIdentity == context.sessionIdentity && recipe.cameraContext.sessionGeneration == context.generation
                && recipe.importedSettings.count == 23 && retained.contains(where: { $0.slot == recipe.slot && $0.name == recipe.name })
        }
    }
    private static func assetIDs() -> Set<String> {
        let fetched = PHAsset.fetchAssets(with: .image, options: NativePhotoWriteGateway.recoveryFetchOptions())
        return Set((0..<fetched.count).map { fetched.object(at: $0).localIdentifier })
    }
    static func validate(source: PhotoSource, retained: RetainedRAWSource, paired: Bool) throws {
        struct Descriptors: Decodable {
            let rafDiscriminator: String
            let jpegOriginalFilename: String?, jpegDiscriminator: String?
        }
        guard let size = try retained.manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65_536 else { throw ResourceError.resourceChanged }
        let descriptors = try JSONDecoder().decode(Descriptors.self, from: Data(contentsOf: retained.manifestURL))
        let raw = source.originalResources.raf
        guard source.id == retained.raw.sourceID, source.resourceRevision == retained.raw.sourceRevision,
              raw.assetID == source.id, raw.sourceRevision == source.resourceRevision, raw.format == .raf,
              raw.role == retained.rafRole, raw.role != .adjusted, raw.originalFilename == retained.originalFilename,
              raw.discriminator == descriptors.rafDiscriminator,
              (source.originalResources.jpeg != nil) == paired else { throw ResourceError.resourceChanged }
        if let jpeg = source.originalResources.jpeg {
            guard jpeg.assetID == source.id, jpeg.sourceRevision == source.resourceRevision, jpeg.format == .jpeg,
                  jpeg.role == retained.jpegRole, jpeg.role != .adjusted, jpeg.role != raw.role,
                  jpeg.originalFilename == descriptors.jpegOriginalFilename, jpeg.discriminator == descriptors.jpegDiscriminator else { throw ResourceError.resourceChanged }
        }
    }
    private func recipe(_ slot: Int, banks: [RecipeSnapshot]) throws -> RecipeSnapshot {
        guard let result = banks.first(where: { $0.slot == slot }) else { throw CameraServiceError.unsupportedSettings }
        _ = try result.normalizedSettings
        return result
    }
    private func preview(_ model: AppModel, source: PhotoSource, recipe: RecipeSnapshot, hash: String) async throws -> (CameraJPEG, DisplayFileLease) {
        try await wait(model) {
            guard let jpeg = model.preview else { return false }
            return jpeg.sourceID == source.id && jpeg.sourceRevision == source.resourceRevision && jpeg.settingsDigest == recipe.settingsDigest
                && model.state.displayedVersion == .preview(jpeg.key) && model.displayFile != nil && model.imageStatus == nil
        }
        guard let jpeg = model.preview, let lease = model.displayFile, jpeg.sourceSHA256 == hash,
              jpeg.cameraContext == model.state.currentCameraExecutionContext,
              try await checksum(lease.fileURL) == jpeg.outputSHA256 else { throw ResourceError.checksumMismatch }
        return (jpeg, lease)
    }
    private func retain(_ jpeg: CameraJPEG, lease: DisplayFileLease, stem: String, run: LiveAcceptanceRun) throws {
        try FileManager.default.copyItem(at: lease.fileURL, to: run.directory.appendingPathComponent(stem + ".JPG"))
        try run.write(jpeg, name: stem + "-record.json")
    }
    private func checksum(_ url: URL) async throws -> String { try await Task.detached { try ResourceChecksum.sha256(url) }.value }
    private func originalHashes(model: AppModel, a: PhotoSource, b: PhotoSource) async throws -> [String: String] {
        guard try await model.environment.reader.source(id: a.id) == a, try await model.environment.reader.source(id: b.id) == b,
              let jpeg = b.originalResources.jpeg else { throw ResourceError.resourceChanged }
        var hashes: [String: String] = [:]
        for (name, token) in [("A-RAF", a.originalResources.raf), ("B-RAF", b.originalResources.raf), ("B-JPEG", jpeg)] {
            let local = try await model.environment.reader.materialize(token, progress: { _ in })
            defer { try? FileManager.default.removeItem(at: local.fileURL) }
            guard local.token == token, try await checksum(local.fileURL) == local.checksum else { throw ResourceError.checksumMismatch }
            hashes[name] = local.checksum
        }
        return hashes
    }
    private func verify(model: AppModel, jobID: UUID, expected: Expected, run: LiveAcceptanceRun, evidence: inout Evidence) async throws {
        guard model.state.libraryAccess == .full else { throw LiveAcceptanceFailure.stopped("Full Photos access required for exact verification") }
        let job = try await model.environment.catalog.job(id: jobID)
        guard job.recipeSnapshot == expected.recipe, job.items.count == 1, let item = job.items.first,
              item.source == expected.sourceB, case .saved(let versionID) = item.state else {
            throw LiveAcceptanceFailure.stopped("Export is not confirmed saved; retain journal and reconcile read-only")
        }
        let versions = try await model.environment.catalog.versions(sourceID: expected.sourceB.id)
        guard let version = versions.first(where: { $0.id == versionID }), version.sourceID == expected.sourceB.id,
              version.operationID == item.operationID, version.recipeSnapshot == expected.recipe,
              version.jpeg == expected.preview.relocated(to: version.jpeg.fileURL),
              !expected.precedingAssetIDs.contains(version.outputAssetID),
              !expected.precedingVersions.contains(where: { $0.id == version.id || $0.outputAssetID == version.outputAssetID }),
              versions.count == expected.precedingVersions.count + 1,
              version.outputAssetID != expected.sourceA.id, version.outputAssetID != expected.sourceB.id else {
            throw LiveAcceptanceFailure.stopped("Saved version identity did not match the one frozen operation")
        }
        let matches = try await NativePhotoWriteGateway().assets(filename: "FujiStudio-\(item.operationID.uuidString).jpg")
        guard matches.count == 1, matches.first?.assetID == version.outputAssetID else { throw LiveAcceptanceFailure.stopped("Photos operation is not uniquely associated") }
        let resources = try await model.environment.reader.resources(assetID: version.outputAssetID)
        let originals = resources.filter { $0.role != .adjusted && $0.format == .jpeg }
        guard originals.count == 1, let token = originals.first, token.originalFilename == "FujiStudio-\(item.operationID.uuidString).jpg" else {
            throw ResourceError.resourceChanged
        }
        let local = try await model.environment.reader.materialize(token, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: local.fileURL) }
        guard local.token == token, try await checksum(local.fileURL) == expected.preview.outputSHA256,
              try await checksum(run.directory.appendingPathComponent("B-C7.JPG")) == expected.preview.outputSHA256 else { throw ResourceError.checksumMismatch }
        guard let image = CGImageSourceCreateWithURL(local.fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any],
              properties[kCGImagePropertyPixelWidth as String] as? Int == expected.preview.width,
              properties[kCGImagePropertyPixelHeight as String] as? Int == expected.preview.height,
              (properties[kCGImagePropertyOrientation as String] as? Int ?? 1) == expected.preview.orientation else { throw CameraServiceError.invalidOutput }
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [version.outputAssetID], options: NativePhotoWriteGateway.recoveryFetchOptions())
        guard asset.count == 1, let saved = asset.firstObject, saved.creationDate == expected.sourceB.captureDate else { throw LiveAcceptanceFailure.stopped("Photos capture date mismatch") }
        let location = saved.location.map { PhotoLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, altitude: $0.altitude) }
        guard location == expected.sourceB.location else { throw LiveAcceptanceFailure.stopped("Photos location mismatch") }
        guard try await originalHashes(model: model, a: expected.sourceA, b: expected.sourceB) == expected.originalHashes else { throw ResourceError.checksumMismatch }
        try run.write(job, name: evidence.reopened ? "reopened-job.json" : "saved-job.json")
        try run.write(version, name: evidence.reopened ? "reopened-version.json" : "saved-version.json")
        model.send(.recipeSelected(slot: nil)); model.send(.sourceTapped(expected.sourceB.id))
        try await wait(model) { model.savedVersions.contains(where: { $0.id == version.id && $0.availability == .available }) }
        model.send(.versionSelected(.saved(version.id)))
        try await wait(model) { model.state.displayedVersion == .saved(version.id) && model.displayFile != nil && model.imageStatus == nil }
        guard let displayed = model.displayFile, try await checksum(displayed.fileURL) == expected.preview.outputSHA256 else { throw ResourceError.checksumMismatch }
        evidence.exactSavedBytes = true; evidence.distinctAsset = true; evidence.captureDatePreserved = true
        evidence.locationPreserved = true; evidence.originalsUnchanged = true; evidence.catalogAssociation = true
        evidence.width = expected.preview.width; evidence.height = expected.preview.height; evidence.orientation = expected.preview.orientation
    }
    private func wait(_ model: AppModel, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while !condition() {
            guard !model.isSuspended, ContinuousClock.now < deadline else { throw LiveAcceptanceFailure.stopped("Validation interrupted or timed out; no automatic retry") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    private func publish(_ evidence: Evidence, run: LiveAcceptanceRun) throws {
        try run.write(evidence, name: "evidence.json")
        status = evidence.stage
        // This public summary contains only booleans/counts/dimensions, never IDs or profile values.
        let documents = run.directory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(evidence).write(to: documents.appendingPathComponent("live-acceptance-evidence.json"), options: [.atomic, .completeFileProtection])
    }
}
#endif
