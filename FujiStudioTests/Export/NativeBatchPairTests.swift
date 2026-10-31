import Foundation
import Testing
@testable import FujiCameraCore
@testable import FujiStudio

@MainActor struct NativeBatchPairTests {
    @Test(arguments: [false, true])
    func verifiesAllPairsAndAlbumOffsetsBeforeOneAtomicRemoval(_ corrupt: Bool) async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try editJPEGFixture(f), library = try BatchPairLibrary(f)
        let service = PhotoLibraryPairer(reader: library, gateway: library,
            journal: PhotoPairJournal(directory: f.root.appendingPathComponent("batch-journal")))
        let batch = UUID()
        var assets: [SavedAsset] = []
        for id in ["raw-A", "raw-B"] {
            let source = try await library.source(id: id)
            let key = RenderKey(sourceID: id, sourceRevision: source.resourceRevision, sourceSHA256: jpeg.sourceSHA256,
                settingsDigest: jpeg.settingsDigest, cameraContext: jpeg.cameraContext, width: jpeg.width, height: jpeg.height,
                orientation: jpeg.orientation, policy: .fullSizeFineRecordedGeometry, quality: jpeg.quality)
            let output = CameraJPEG(fileURL: jpeg.fileURL, sourceID: id, sourceRevision: source.resourceRevision,
                sourceSHA256: jpeg.sourceSHA256, recipeSnapshotID: jpeg.recipeSnapshotID, settingsDigest: jpeg.settingsDigest,
                cameraContext: jpeg.cameraContext, operationID: jpeg.operationID, width: jpeg.width, height: jpeg.height,
                orientation: jpeg.orientation, quality: jpeg.quality, effectiveRecipe: jpeg.effectiveRecipe,
                baselineSHA256: jpeg.baselineSHA256, candidateSHA256: jpeg.candidateSHA256, outputSHA256: jpeg.outputSHA256, key: key)
            let request = PhotoSaveRequest(jpeg: output, operationID: UUID(), captureDate: source.captureDate, location: nil,
                deferPairRemoval: true, pairBatchID: batch)
            assets.append(try await service.saveJPEG(request, edit: .init(source: source, recipe: f.recipe)) { _ in })
        }
        #expect(await library.originals == ["raw-A", "raw-B"])
        #expect(await library.deletionBatches.isEmpty)
        // B was inserted ahead of A in the same album after A's snapshot was taken.
        #expect(try await service.findExport(operationID: assets[0].operationID, sourceID: "raw-A", knownAssetID: assets[0].assetID)
            == .needsReplacementCleanup(assets[0]))
        if corrupt {
            await library.corruptRAW(assets[0].assetID)
            await #expect(throws: ResourceError.self) { try await service.completeReplacements(assets, allowingPreviousEdits: false) }
            #expect(await library.originals == ["raw-A", "raw-B"])
            #expect(await library.deletionBatches.isEmpty)
            _ = try await service.completeReplacements([assets[1]], allowingPreviousEdits: false)
            try await library.restoreRAW(assets[0].assetID)
            _ = try await service.completeReplacements([assets[0]], allowingPreviousEdits: false)
            #expect(await library.deletionBatches == [["raw-B"], ["raw-A"]])
            #expect(await library.originals.isEmpty)
        } else {
            #expect(try await service.completeReplacements(assets, allowingPreviousEdits: false) == assets)
            #expect(await library.deletionBatches == [["raw-A", "raw-B"]])
            #expect(await library.originals.isEmpty)
            #expect(await library.album == [assets[1].assetID, "other", assets[0].assetID])
        }
    }
}

private actor BatchPairLibrary: PhotoLibraryReading, PhotoPairGateway {
    let f: RenderFixture
    private var index: [String: PhotoSource] = [:]
    private var metadata: [String: PhotoPairAssetState] = [:]
    private var raws: [String: Data] = [:], jpegs: [String: Data] = [:]
    private(set) var album = ["raw-B", "other", "raw-A"]
    private(set) var originals: Set<String> = ["raw-A", "raw-B"]
    private(set) var deletionBatches: [[String]] = []
    init(_ f: RenderFixture) throws {
        self.f = f
        for id in ["raw-A", "raw-B"] {
            let raw = ResourceToken(assetID: id, role: .primaryOriginal, contentTypeIdentifier: "com.fuji.raw-image",
                format: .raf, originalFilename: "original.RAF", discriminator: "raw", sourceRevision: "v1")
            index[id] = PhotoSource(id: id, originalResources: .init(raf: raw, jpeg: nil), captureDate: nil, location: nil, resourceRevision: "v1")
            raws[id] = try Data(contentsOf: f.raw.fileURL)
            metadata[id] = .init(assetID: id, modificationDate: Date(timeIntervalSince1970: 100), captureDate: nil,
                location: nil, isFavorite: true, isHidden: false, caption: "Retain", rating: 3,
                keywords: [], albumIDs: ["album"])
        }
    }
    func access() -> LibraryAccess { .full }
    func state(assetID: String) -> PhotoPairAssetState? {
        guard var value = metadata[assetID], let position = album.firstIndex(of: assetID) else { return nil }
        value.albumPositions = ["album": position]
        return value
    }
    func corruptRAW(_ id: String) { raws[id] = Data([0]) }
    func restoreRAW(_ id: String) throws { raws[id] = try Data(contentsOf: f.raw.fileURL) }
    func createPair(intent: PhotoPairIntent, rawURL: URL, jpegURL: URL,
                    onPlaceholder: @escaping @Sendable (String) -> Void) throws -> String {
        let id = "pair-\(intent.operationID)", revision = "v2"
        let raw = ResourceToken(assetID: id, role: .alternateOriginal, contentTypeIdentifier: "com.fuji.raw-image",
            format: .raf, originalFilename: intent.filename + ".RAF", discriminator: "raw", sourceRevision: revision)
        let jpeg = ResourceToken(assetID: id, role: .primaryOriginal, contentTypeIdentifier: "public.jpeg",
            format: .jpeg, originalFilename: intent.filename, discriminator: "jpeg", sourceRevision: revision)
        index[id] = .init(id: id, originalResources: .init(raf: raw, jpeg: jpeg), captureDate: nil, location: nil, resourceRevision: revision)
        raws[id] = try Data(contentsOf: rawURL); jpegs[id] = try Data(contentsOf: jpegURL)
        var value = intent.originalState; value.assetID = id; metadata[id] = value
        album.insert(id, at: try #require(album.firstIndex(of: intent.source.id)))
        onPlaceholder(id); return id
    }
    func matchingAssets(filename: String) -> [String] { index.values.filter { $0.originalResources.jpeg?.originalFilename == filename }.map(\.id) }
    func removeOriginals(_ removals: [PhotoPairRemoval]) throws {
        for removal in removals {
            guard state(assetID: removal.intent.source.id) == removal.intent.removalOriginalState,
                  state(assetID: removal.verified.source.id) == removal.verified.state else { throw ResourceError.resourceChanged }
        }
        let ids = removals.map { $0.intent.source.id }
        deletionBatches.append(ids)
        for id in ids { index[id] = nil; metadata[id] = nil; originals.remove(id) }
        album.removeAll { ids.contains($0) }
    }
    func requestAccess() -> LibraryAccess { .full }
    func source(id: SourceID) throws -> PhotoSource {
        guard let source = index[id] else { throw ResourceError.inaccessibleAsset(id) }; return source
    }
    func sources() -> AsyncThrowingStream<[PhotoSource], Error> { AsyncThrowingStream { $0.yield(Array(index.values)); $0.finish() } }
    func resources(assetID: String) throws -> [ResourceToken] {
        let source = try source(id: assetID)
        return [source.originalResources.raf] + (source.originalResources.jpeg.map { [$0] } ?? [])
    }
    func rawMetadata(_ resource: ResourceToken) -> RAWMetadata { f.raw.metadata }
    func changes() -> AsyncStream<LibraryChange> { AsyncStream { $0.finish() } }
    func materialize(_ resource: ResourceToken, progress: @escaping @Sendable (Double) -> Void) throws -> LocalResource {
        let bytes = try #require(resource.format == .raf ? raws[resource.assetID] : jpegs[resource.assetID])
        let url = f.root.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url)
        return LocalResource(token: resource, fileURL: url, checksum: try ResourceChecksum.sha256(url))
    }
}
