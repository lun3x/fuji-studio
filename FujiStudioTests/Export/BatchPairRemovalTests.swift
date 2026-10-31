import Foundation
import Testing
@testable import FujiCameraCore
@testable import FujiStudio

struct BatchPairRemovalTests {
    private func batch(_ f: ExportBatchFixture, writer: BatchRemovalWriter) -> (ExportCoordinator, [PhotoSource]) {
        let sources = f.sources.map { PhotoSource(id: $0.id, originalResources: .init(raf: $0.originalResources.raf, jpeg: nil),
            captureDate: $0.captureDate, location: $0.location, resourceRevision: $0.resourceRevision) }
        let reader = BatchReader(f.render, sources: sources)
        return (ExportCoordinator(reader: reader, camera: f.camera, catalog: f.catalog, writer: writer,
            pool: reader.pool(), cache: f.cache, scheduler: f.scheduler), sources)
    }
    @Test func actualBackgroundDuringConfirmationDrainsTheBatchWithoutRequiringResume() async throws {
        let f = try ExportBatchFixture(), writer = BatchRemovalWriter(), gate = RenderLatch()
        let (engine, sources) = batch(f, writer: writer)
        await writer.holdCleanup(gate)
        var events = await engine.events().makeAsyncIterator()
        let id = try await engine.start(sources: sources, recipe: f.render.recipe, destination: .updateOriginal)
        await gate.entered()
        #expect(await writer.requests.count == 2)
        let suspension = Task { await engine.suspend() }
        while let event = await events.next() { if event.stopRequested { break } }
        await gate.release(); await suspension.value
        while let event = await events.next() { if event.terminal { #expect(event.summary.completed == 2 && event.summary.unprocessed == 0); break } }
        #expect(try await f.catalog.job(id: id).state == .saved)
        #expect(await writer.removalTransactions == 1)
    }
    @Test func resumeFinishesRemainingConversionsBeforeRemovingTheStagedOriginalsTogether() async throws {
        let f = try ExportBatchFixture(), writer = BatchRemovalWriter(), gate = RenderLatch()
        let (engine, sources) = batch(f, writer: writer)
        await writer.holdSave(gate)
        var events = await engine.events().makeAsyncIterator()
        let id = try await engine.start(sources: sources, recipe: f.render.recipe, destination: .updateOriginal)
        await gate.entered()
        let pause = Task { await engine.pause(jobID: id) }
        while let event = await events.next() { if event.stopRequested { break } }
        await gate.release(); await pause.value
        while let event = await events.next() { if event.terminal { break } }
        #expect(await writer.removalTransactions == 0)
        #expect(await writer.requests.count == 1)
        try await engine.resume(jobID: id)
        while let event = await events.next() { if event.terminal { #expect(event.summary.completed == 2); break } }
        #expect(await writer.events == ["save", "save", "remove:2"])
        #expect(await f.camera.sources.count == 2)
    }
    @Test func createsEveryPairBeforeOneRemovalTransaction() async throws {
        let f = try ExportBatchFixture(), writer = BatchRemovalWriter()
        let sources = f.sources.map { PhotoSource(id: $0.id, originalResources: .init(raf: $0.originalResources.raf, jpeg: nil),
            captureDate: $0.captureDate, location: $0.location, resourceRevision: $0.resourceRevision) }
        let reader = BatchReader(f.render, sources: sources)
        let engine = ExportCoordinator(reader: reader, camera: f.camera, catalog: f.catalog, writer: writer,
            pool: reader.pool(), cache: f.cache, scheduler: f.scheduler)
        var events = await engine.events().makeAsyncIterator()
        let id = try await engine.start(sources: sources, recipe: f.render.recipe, destination: .updateOriginal)
        while let event = await events.next() { if event.jobID == id && event.terminal { break } }
        #expect(await writer.events == ["save", "save", "remove:2"])
        #expect(await writer.removalTransactions == 1)
        #expect(try await f.catalog.job(id: id).state == .saved)
        #expect(await f.camera.sources.count == 2)
        #expect((await writer.requests).allSatisfy { $0.pairBatchID == id && $0.deferPairRemoval })
    }
}

actor BatchRemovalWriter: PhotoLibraryWriting {
    private(set) var events: [String] = []
    private(set) var removalTransactions = 0
    private(set) var requests: [PhotoSaveRequest] = []
    private var assets: [UUID: SavedAsset] = [:]
    private var saveGate: RenderLatch?
    private var cleanupGate: RenderLatch?
    func holdSave(_ gate: RenderLatch) { saveGate = gate }
    func holdCleanup(_ gate: RenderLatch) { cleanupGate = gate }
    func saveJPEG(_ request: PhotoSaveRequest, onPlaceholder: @escaping @Sendable (String) -> Void) async throws -> SavedAsset {
        requests.append(request); events.append("save")
        let asset = SavedAsset(assetID: "pair-\(request.operationID)", operationID: request.operationID, photosGeometry: nil)
        assets[request.operationID] = asset; onPlaceholder(asset.assetID)
        if let saveGate { await saveGate.wait() }
        if !request.deferPairRemoval { events.append("remove:1"); removalTransactions += 1 }
        return asset
    }
    func findExport(operationID: UUID, knownAssetID: String?, originalAssetID: String?) async throws -> SaveLookup {
        guard let asset = assets[operationID] else { return .notFound }
        return .needsReplacementCleanup(asset)
    }
    func completeReplacements(_ assets: [SavedAsset], allowingPreviousEdits: Bool) async throws -> [SavedAsset] {
        events.append("remove:\(assets.count)"); removalTransactions += 1
        if let cleanupGate { await cleanupGate.wait() }
        return assets
    }
}
