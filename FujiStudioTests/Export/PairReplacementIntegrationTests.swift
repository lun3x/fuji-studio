import Foundation
import Testing
@testable import FujiCameraCore
@testable import FujiStudio

@MainActor struct PairReplacementIntegrationTests {
    @Test func writerRoutesRAWOnlyToPairCreationAndExistingPairsToReversibleEdits() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try editJPEGFixture(f), library = try PairTestLibrary(f, jpeg: jpeg)
        let edits = TestPhotoEditGateway(root: f.root, assetID: f.source.id)
        let writer = PhotoLibraryWriter(editor: PhotoLibraryEditor(gateway: edits), pairer: PhotoLibraryPairer(
            reader: library, gateway: library, journal: PhotoPairJournal(directory: f.root.appendingPathComponent("pairs"))))
        let rawOnly = PhotoSaveRequest(jpeg: jpeg, operationID: UUID(), captureDate: nil, location: nil,
            originalEdit: .init(source: f.source, recipe: f.recipe))
        #expect(try await writer.saveJPEG(rawOnly) { _ in }.assetID == "paired-asset")
        #expect(edits.session.commits == 0)
        let existingPair = pairReplacementSource(f.source, id: f.source.id, revision: f.source.resourceRevision)
        let pairEdit = PhotoSaveRequest(jpeg: jpeg, operationID: UUID(), captureDate: nil, location: nil,
            originalEdit: .init(source: existingPair, recipe: f.recipe))
        #expect(try await writer.saveJPEG(pairEdit) { _ in }.assetID == f.source.id)
        #expect(edits.session.commits == 1)
        #expect(await library.creations == 1)
    }

    @Test(arguments: [false, true])
    func catalogAliasPreservesHistoryAndFrozenJobBeforeOrAfterConfirmation(_ before: Bool) async throws {
        let f = try RenderFixture()
        let store = f.root.appendingPathComponent("catalog.store"), catalog = try SwiftDataCatalog(storeURL: store)
        let jpeg = try f.jpeg(), replacement = pairReplacementSource(f.source)
        let first = pendingJob(f, jpeg: jpeg, destination: .separatePhoto, outputID: "earlier-jpeg", at: 10)
        try await catalog.saveJob(first.job)
        try await catalog.confirmSaved(jobID: first.job.id, operationID: first.version.operationID, version: first.version)
        let second = pendingJob(f, jpeg: jpeg, destination: .updateOriginal, outputID: replacement.id, at: 20)
        try await catalog.saveJob(second.job)
        if before { try await catalog.replaceSource(f.source.id, with: replacement) }
        try await catalog.confirmSaved(jobID: second.job.id, operationID: second.version.operationID, version: second.version)
        if !before { try await catalog.replaceSource(f.source.id, with: replacement) }
        let reopened = try SwiftDataCatalog(storeURL: store)
        let versions = try await reopened.versions(sourceID: replacement.id)
        #expect(versions.map(\.id) == [first.version.id, second.version.id])
        #expect(versions.allSatisfy { $0.sourceID == replacement.id })
        #expect(versions.first?.jpeg == jpeg)
        #expect(try await reopened.job(id: second.job.id).items[0].source == f.source)
        try await reopened.confirmSaved(jobID: second.job.id, operationID: second.version.operationID, version: second.version)
        #expect(try await reopened.versions(sourceID: replacement.id).count == 2)
    }

    @Test func replacementKeepsViewedAndCheckedPhotoAndFrozenActiveJob() throws {
        let f = try RenderFixture(); defer { f.remove() }
        let replacement = pairReplacementSource(f.source), job = UUID()
        var state = WorkspaceState(sources: [f.source], access: .full)
        state.reduce(.sourceTapped(f.source.id)); state.reduce(.select); state.reduce(.activeJobChanged(job))
        state.reduce(.sourceReplaced(f.source.id, with: replacement))
        #expect(state.viewedSourceID == replacement.id)
        #expect(state.checkedSourceIDs == [replacement.id])
        #expect(state.displayedVersion == .cameraJPEG)
        #expect(state.activeJobID == job)
        #expect(state.effectiveSources == [replacement])
    }

    @Test func passiveRecoveryDoesNotRemoveOriginalAndResumeFinishesPairWithoutRenderingAgain() async throws {
        let f = try RenderFixture(), reader = RenderLibrary(f), cache = try f.cache()
        let catalog = try SwiftDataCatalog(storeURL: f.root.appendingPathComponent("catalog.store"))
        let writer = PairCleanupWriter(), camera = RenderCamera(f)
        let engine = ExportCoordinator(reader: reader, camera: camera, catalog: catalog, writer: writer,
            pool: reader.pool(), cache: cache, scheduler: CameraWorkScheduler())
        var events = await engine.events().makeAsyncIterator()
        let id = try await engine.start(sources: [f.source], recipe: f.recipe, destination: .updateOriginal)
        while let event = await events.next() { if event.jobID == id && event.terminal { break } }
        let recovery = try await engine.recover()
        #expect(recovery.jobs.first?.summary.unresolved == 1)
        #expect(await writer.cleanupCalls == 0)
        #expect(await camera.calls == 1)
        #expect(!(await cache.pinnedKeys()).isEmpty)
        try await engine.resume(jobID: id)
        while let event = await events.next() { if event.jobID == id && event.terminal { break } }
        #expect(await writer.cleanupCalls == 1)
        #expect(await writer.requests == 1)
        #expect(await camera.calls == 1)
        #expect(try await catalog.job(id: id).state == .saved)
        #expect(try await catalog.versions(sourceID: f.source.id).first?.destination == .createPair)
        #expect((await cache.pinnedKeys()).isEmpty)
    }

    private func pendingJob(_ f: RenderFixture, jpeg: CameraJPEG, destination: ExportDestination,
                            outputID: String, at: TimeInterval) -> (job: ExportJob, version: SavedVersion) {
        let operation = UUID(), date = Date(timeIntervalSince1970: at)
        let pending = PendingSave(operationID: operation, jpeg: jpeg, placeholderID: outputID, submission: .submitted(at: date))
        let job = ExportJob(id: UUID(), submittedAt: date, recipeSnapshot: f.recipe,
            items: [.init(source: f.source, operationID: operation, state: .pendingSave(pending))], state: .pendingSave, destination: destination)
        let version = SavedVersion(id: UUID(), sourceID: f.source.id, outputAssetID: outputID, recipeSnapshot: f.recipe,
            operationID: operation, exportedAt: date, jpeg: jpeg, availability: .available,
            destination: destination == .updateOriginal ? .createPair : .separatePhoto)
        return (job, version)
    }
}

func pairReplacementSource(_ source: PhotoSource, id: String = "paired-asset", revision: String = "paired-revision") -> PhotoSource {
    var raf = source.originalResources.raf
    raf = ResourceToken(assetID: id, role: .alternateOriginal, contentTypeIdentifier: raf.contentTypeIdentifier,
        format: .raf, originalFilename: raf.originalFilename, discriminator: "pair-raf", sourceRevision: revision)
    let jpeg = ResourceToken(assetID: id, role: .primaryOriginal, contentTypeIdentifier: "public.jpeg", format: .jpeg,
        originalFilename: "paired.JPG", discriminator: "pair-jpeg", sourceRevision: revision)
    return PhotoSource(id: id, originalResources: .init(raf: raf, jpeg: jpeg), captureDate: source.captureDate,
        location: source.location, resourceRevision: revision, compatibility: source.compatibility)
}

private actor PairCleanupWriter: PhotoLibraryWriting {
    private(set) var requests = 0
    private(set) var cleanupCalls = 0
    func saveJPEG(_ request: PhotoSaveRequest, onPlaceholder: @escaping @Sendable (String) -> Void) throws -> SavedAsset {
        requests += 1; onPlaceholder("paired-asset")
        throw PhotoLibraryWriteError.uncertain(.missingConfirmation)
    }
    func findExport(operationID: UUID, knownAssetID: String?, originalAssetID: String?) -> SaveLookup {
        let asset = SavedAsset(assetID: "paired-asset", operationID: operationID, photosGeometry: nil)
        return cleanupCalls == 0 ? .needsReplacementCleanup(asset) : .found(asset)
    }
    func completeReplacement(operationID: UUID, assetID: String) -> SavedAsset {
        cleanupCalls += 1
        return SavedAsset(assetID: assetID, operationID: operationID, photosGeometry: nil)
    }
}
