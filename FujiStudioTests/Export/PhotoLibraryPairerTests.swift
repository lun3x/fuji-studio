import Foundation
import Testing
@testable import FujiCameraCore
@testable import FujiStudio

@MainActor struct PhotoLibraryPairerTests {
    @Test func aDeferredPairRetainsTheOriginalUntilBatchCleanup() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try editJPEGFixture(f), library = try PairTestLibrary(f, jpeg: jpeg)
        var request = request(f, jpeg)
        request.deferPairRemoval = true; request.pairBatchID = UUID()
        let service = pairer(f, library)
        let asset = try await service.saveJPEG(request, edit: .init(source: f.source, recipe: f.recipe)) { _ in }
        #expect(await library.removals == 0)
        #expect(await library.originalExists)
        #expect(try await service.findExport(operationID: request.operationID, sourceID: f.source.id,
            knownAssetID: asset.assetID) == .needsReplacementCleanup(asset))
    }
    @Test func PhotosRenamingThePairedRAWDoesNotOverrideByteVerification() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try editJPEGFixture(f), library = try PairTestLibrary(f, jpeg: jpeg)
        await library.setFault("rawRenamed")
        let saved = try await pairer(f, library).saveJPEG(request(f, jpeg), edit: .init(source: f.source, recipe: f.recipe)) { _ in }
        #expect(saved.assetID == "paired-asset")
        #expect(await library.removals == 1)
    }
    @Test func verifiedPairWithAnOlderReversibleEditCanBeFinishedExplicitlyWithoutAnotherCreation() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try editJPEGFixture(f), library = try PairTestLibrary(f, jpeg: jpeg), request = request(f, jpeg)
        let service = pairer(f, library)
        await library.setFault("originalChanged")
        do { _ = try await service.saveJPEG(request, edit: .init(source: f.source, recipe: f.recipe)) { _ in } }
        catch PhotoLibraryWriteError.uncertain { }
        let asset = SavedAsset(assetID: "paired-asset", operationID: request.operationID, photosGeometry: nil)
        #expect(try await service.findExport(operationID: request.operationID, sourceID: f.source.id, knownAssetID: asset.assetID)
            == .needsReplacementCleanup(asset))
        #expect(await library.removals == 0)
        #expect(try await service.completeReplacement(operationID: request.operationID, assetID: asset.assetID) == asset)
        #expect(await library.creations == 1)
        #expect(await library.removals == 1)
    }
    @Test(arguments: [false, true])
    func explicitCleanupStillRejectsAChangedRAWOrAnEditDuringVerification(_ bytesChanged: Bool) async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try editJPEGFixture(f), library = try PairTestLibrary(f, jpeg: jpeg), request = request(f, jpeg)
        let service = pairer(f, library)
        await library.setFault("removeRejected")
        do { _ = try await service.saveJPEG(request, edit: .init(source: f.source, recipe: f.recipe)) { _ in } }
        catch PhotoLibraryWriteError.uncertain { }
        if bytesChanged { await library.setFault(nil); await library.corruptOriginalRAW() }
        else { await library.setFault("lateOriginalChange") }
        do { _ = try await service.completeReplacement(operationID: request.operationID, assetID: "paired-asset"); Issue.record("A changed original must be retained") }
        catch { }
        #expect(await library.originalExists)
        #expect(await library.removals == 0)
    }
    @Test func copiesOriginalBytesAndMetadataAndVerifiesBothResourcesBeforeRemovingRAW() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try editJPEGFixture(f), library = try PairTestLibrary(f, jpeg: jpeg)
        let service = pairer(f, library), request = request(f, jpeg)
        let saved = try await service.saveJPEG(request, edit: .init(source: f.source, recipe: f.recipe)) { _ in }
        #expect(saved.assetID == "paired-asset")
        #expect(saved.operationID == request.operationID)
        #expect(await library.creations == 1)
        #expect(await library.removals == 1)
        #expect(await library.originalExists == false)
        #expect(await library.createdMetadata == library.originalMetadata)
        #expect(await library.events == ["create", "read-pair-raw", "read-pair-jpeg", "remove"])
        #expect(try await service.sourceReplacements() == [f.source.id: "paired-asset"])
    }

    @Test(arguments: ["raw", "jpeg", "originalChanged", "pairChanged", "metadataMissing", "originalReordered"])
    func failedVerificationOrChangedAssetsNeverRemoveOriginal(_ fault: String) async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try editJPEGFixture(f), library = try PairTestLibrary(f, jpeg: jpeg)
        await library.setFault(fault)
        do {
            _ = try await pairer(f, library).saveJPEG(request(f, jpeg), edit: .init(source: f.source, recipe: f.recipe)) { _ in }
            Issue.record("A changed or corrupt replacement cannot remove the original")
        } catch PhotoLibraryWriteError.uncertain { }
        #expect(await library.originalExists)
        #expect(await library.removals == 0)
    }

    @Test func interruptedRemovalReopensJournalAndRequiresExplicitCleanupWithoutAnotherCreation() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try editJPEGFixture(f), library = try PairTestLibrary(f, jpeg: jpeg)
        let request = request(f, jpeg), service = pairer(f, library)
        await library.setFault("removeRejected")
        do {
            _ = try await service.saveJPEG(request, edit: .init(source: f.source, recipe: f.recipe)) { _ in }
            Issue.record("Removal rejection must leave an unresolved operation")
        } catch PhotoLibraryWriteError.uncertain { }
        let reopened = pairer(f, library)
        let asset = SavedAsset(assetID: "paired-asset", operationID: request.operationID, photosGeometry: nil)
        #expect(try await reopened.findExport(operationID: request.operationID, sourceID: f.source.id, knownAssetID: nil)
            == .needsReplacementCleanup(asset))
        #expect(await library.removals == 0) // Passive lookup must never write to Photos.
        await library.setFault(nil)
        #expect(try await reopened.completeReplacement(operationID: request.operationID, assetID: asset.assetID) == asset)
        #expect(await library.creations == 1)
        #expect(await library.removals == 1)
        #expect(try await reopened.findExport(operationID: request.operationID, sourceID: f.source.id, knownAssetID: asset.assetID) == .found(asset))
    }

    @Test func readBackMismatchCannotBeHiddenByAStoredVerifiedReceipt() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try editJPEGFixture(f), library = try PairTestLibrary(f, jpeg: jpeg)
        let request = request(f, jpeg), service = pairer(f, library)
        await library.setFault("removeRejected")
        do { _ = try await service.saveJPEG(request, edit: .init(source: f.source, recipe: f.recipe)) { _ in } }
        catch PhotoLibraryWriteError.uncertain { }
        #expect(await library.creations == 1)
        #expect(try await service.sourceReplacements() == [f.source.id: "paired-asset"])
        await library.corruptPairRAW()
        do {
            _ = try await pairer(f, library).completeReplacement(operationID: request.operationID, assetID: "paired-asset")
            Issue.record("Cleanup must reverify the actual pair")
        } catch { }
        #expect(await library.originalExists)
        #expect(await library.removals == 0)
    }

    @Test func failedIntentPersistenceCannotStartCreation() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try editJPEGFixture(f), library = try PairTestLibrary(f, jpeg: jpeg)
        let blocked = f.root.appendingPathComponent("blocked")
        try Data([1]).write(to: blocked)
        let service = PhotoLibraryPairer(reader: library, gateway: library,
            journal: PhotoPairJournal(directory: blocked.appendingPathComponent("child")))
        do {
            _ = try await service.saveJPEG(request(f, jpeg), edit: .init(source: f.source, recipe: f.recipe)) { _ in }
            Issue.record("No Photos transaction is allowed without a durable intent")
        } catch PhotoLibraryWriteError.invalidOutput { }
        catch PhotoLibraryWriteError.rejected { }
        catch { Issue.record("A failed preflight must be definitive, not an uncertain submission: \(error)") }
        #expect(await library.creations == 0)
        #expect(await library.originalExists)
    }

    @Test func unavailableOriginalPreparationIsDefinitiveAndNeverSubmits() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try editJPEGFixture(f), library = try PairTestLibrary(f, jpeg: jpeg)
        await library.setFault("sourceUnavailable")
        do {
            _ = try await pairer(f, library).saveJPEG(request(f, jpeg), edit: .init(source: f.source, recipe: f.recipe)) { _ in }
            Issue.record("An inaccessible RAW must not submit a pair")
        } catch PhotoLibraryWriteError.invalidOutput { }
        catch { Issue.record("Preparation must fail definitively: \(error)") }
        #expect(await library.creations == 0)
        #expect(await library.originalExists)
    }

    @Test func confirmedRemovalRecoversUnderLimitedAccessWithoutAssumingAnAbsentRAWWasDeleted() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try editJPEGFixture(f), library = try PairTestLibrary(f, jpeg: jpeg), request = request(f, jpeg)
        let asset = try await pairer(f, library).saveJPEG(request, edit: .init(source: f.source, recipe: f.recipe)) { _ in }
        await library.setAccess(.limited)
        #expect(try await pairer(f, library).findExport(operationID: request.operationID, sourceID: f.source.id, knownAssetID: asset.assetID) == .found(asset))
    }

    @Test func passiveLookupCannotPromoteAPairThatLostOriginalMetadata() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try editJPEGFixture(f), library = try PairTestLibrary(f, jpeg: jpeg), request = request(f, jpeg)
        await library.setFault("metadataMissing")
        do { _ = try await pairer(f, library).saveJPEG(request, edit: .init(source: f.source, recipe: f.recipe)) { _ in } }
        catch PhotoLibraryWriteError.uncertain { }
        await #expect(throws: ResourceError.self) {
            try await pairer(f, library).findExport(operationID: request.operationID, sourceID: f.source.id, knownAssetID: "paired-asset")
        }
        #expect(try await pairer(f, library).sourceReplacements().isEmpty)
        #expect(await library.originalExists)
    }

    @Test func cancellationWaitsForCreationAndNeverBecomesPermissionToResubmit() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try editJPEGFixture(f), library = try PairTestLibrary(f, jpeg: jpeg), request = request(f, jpeg)
        let gate = RenderLatch(), service = pairer(f, library)
        await library.holdCreation(gate)
        let task = Task { try await service.saveJPEG(request, edit: .init(source: f.source, recipe: f.recipe)) { _ in } }
        await gate.entered()
        task.cancel()
        for url in await library.submittedFiles { #expect(FileManager.default.fileExists(atPath: url.path)) }
        await gate.release()
        do { _ = try await task.value; Issue.record("Canceled verification cannot remove the original") }
        catch PhotoLibraryWriteError.uncertain { }
        #expect(await library.originalExists)
        #expect(await library.creations == 1)
        #expect(try await service.findExport(operationID: request.operationID, sourceID: f.source.id, knownAssetID: nil)
            == .needsReplacementCleanup(.init(assetID: "paired-asset", operationID: request.operationID, photosGeometry: nil)))
        #expect(await library.removals == 0)
    }

    @Test(arguments: [false, true])
    func limitedToFullAccessCannotTurnAnInaccessibleOriginalIntoARemovalReceipt(_ cleanup: Bool) async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try editJPEGFixture(f), library = try PairTestLibrary(f, jpeg: jpeg), request = request(f, jpeg)
        let service = pairer(f, library)
        await library.setFault("removeRejected")
        do { _ = try await service.saveJPEG(request, edit: .init(source: f.source, recipe: f.recipe)) { _ in } }
        catch PhotoLibraryWriteError.uncertain { }
        await library.setFault(nil)
        await library.expandAccessDuringOriginalLookup()
        if cleanup {
            await #expect(throws: PhotoLibraryWriteError.self) {
                try await service.completeReplacement(operationID: request.operationID, assetID: "paired-asset")
            }
        } else {
            #expect(try await service.findExport(operationID: request.operationID, sourceID: f.source.id,
                knownAssetID: "paired-asset") == .inaccessible)
        }
        #expect(try await service.journal.intent(request.operationID)?.phase != .removed)
        #expect(await library.originalExists)
        #expect(await library.removals == 0)
    }

    private func pairer(_ f: RenderFixture, _ library: PairTestLibrary) -> PhotoLibraryPairer {
        PhotoLibraryPairer(reader: library, gateway: library, journal: PhotoPairJournal(directory: f.root.appendingPathComponent("pairs")))
    }
    private func request(_ f: RenderFixture, _ jpeg: CameraJPEG) -> PhotoSaveRequest {
        .init(jpeg: jpeg, operationID: UUID(), captureDate: f.source.captureDate, location: f.source.location)
    }
}

actor PairTestLibrary: PhotoLibraryReading, PhotoPairGateway {
    let fixture: RenderFixture
    let originalMetadata: PhotoPairAssetState
    private var raw: Data
    private let jpeg: Data
    private var pairRAW: Data?
    private var pairJPEG: Data?
    private var paired: PhotoSource?
    private var fault: String?
    private var transfers = 0
    private var pairState: PhotoPairAssetState?
    private var accessValue: LibraryAccess = .full
    private var creationGate: RenderLatch?
    private var expandAccessOnLookup = false
    private var originalAlbumPosition = 3
    private(set) var submittedFiles: [URL] = []
    private(set) var originalExists = true
    private(set) var creations = 0
    private(set) var removals = 0
    private(set) var events: [String] = []
    private(set) var createdMetadata: PhotoPairAssetState?
    init(_ fixture: RenderFixture, jpeg: CameraJPEG) throws {
        self.fixture = fixture
        raw = try Data(contentsOf: fixture.raw.fileURL); self.jpeg = try Data(contentsOf: jpeg.fileURL)
        originalMetadata = .init(assetID: fixture.source.id, modificationDate: Date(timeIntervalSince1970: 100),
            captureDate: Date(timeIntervalSince1970: 10), location: nil, isFavorite: true, isHidden: false,
            caption: "Keep this caption", rating: 4, keywords: ["Travel"], albumIDs: ["album"], albumPositions: ["album": 3])
    }
    func setFault(_ fault: String?) { self.fault = fault }
    func corruptPairRAW() { pairRAW = Data([0]) }
    func corruptOriginalRAW() { raw = Data([0]) }
    func access() -> LibraryAccess { accessValue }
    func setAccess(_ value: LibraryAccess) { accessValue = value }
    func holdCreation(_ gate: RenderLatch) { creationGate = gate }
    func expandAccessDuringOriginalLookup() { accessValue = .limited; expandAccessOnLookup = true }
    func state(assetID: String) -> PhotoPairAssetState? {
        if assetID == fixture.source.id {
            guard originalExists else { return nil }
            if expandAccessOnLookup { expandAccessOnLookup = false; accessValue = .full; return nil }
            var state = originalMetadata
            state.albumPositions["album"] = originalAlbumPosition
            if fault == "originalChanged", creations > 0 { state.modificationDate = Date(timeIntervalSince1970: 200) }
            return state
        }
        return pairState
    }
    func createPair(intent: PhotoPairIntent, rawURL: URL, jpegURL: URL,
                    onPlaceholder: @escaping @Sendable (String) -> Void) async throws -> String {
        creations += 1; events.append("create"); createdMetadata = intent.originalState
        originalAlbumPosition += 1
        submittedFiles = [rawURL, jpegURL]
        pairRAW = try Data(contentsOf: rawURL); pairJPEG = try Data(contentsOf: jpegURL)
        if fault == "raw" { pairRAW?.append(0) }
        if fault == "jpeg" { pairJPEG = Data([0]) }
        let id = "paired-asset", revision = "paired-revision"
        let raf = ResourceToken(assetID: id, role: .alternateOriginal, contentTypeIdentifier: "com.fuji.raw-image",
            format: .raf, originalFilename: fault == "rawRenamed" ? "FujiStudio-renamed.RAF" : fixture.token.originalFilename,
            discriminator: "pair-raw", sourceRevision: revision)
        let jpeg = ResourceToken(assetID: id, role: .primaryOriginal, contentTypeIdentifier: "public.jpeg",
            format: .jpeg, originalFilename: intent.filename, discriminator: "pair-jpeg", sourceRevision: revision)
        paired = .init(id: id, originalResources: .init(raf: raf, jpeg: jpeg), captureDate: intent.source.captureDate,
            location: intent.source.location, resourceRevision: revision)
        var state = originalMetadata; state.assetID = id
        if fault == "metadataMissing" { state.caption = nil }
        pairState = state
        onPlaceholder(id)
        if let creationGate { await creationGate.wait() }
        return id
    }
    func matchingAssets(filename: String) -> [String] { paired?.originalResources.jpeg?.originalFilename == filename ? ["paired-asset"] : [] }
    func removeOriginals(_ removals: [PhotoPairRemoval]) throws {
        guard removals.count == 1, let removal = removals.first else { throw ResourceError.resourceChanged }
        let intent = removal.intent, verified = removal.verified
        if fault == "removeRejected" { throw PhotoLibraryWriteError.rejected(.authorization) }
        guard state(assetID: intent.source.id) == (intent.removalOriginalState ?? intent.originalState.afterPairInsertion()),
              state(assetID: verified.source.id) == verified.state else { throw ResourceError.resourceChanged }
        self.removals += 1; events.append("remove"); originalExists = false
    }
    func requestAccess() -> LibraryAccess { .full }
    func sources() -> AsyncThrowingStream<[PhotoSource], Error> { AsyncThrowingStream { $0.finish() } }
    func source(id: SourceID) throws -> PhotoSource {
        if id == fixture.source.id, fault == "sourceUnavailable" { throw ResourceError.retrievalFailed("Original is offline") }
        if id == fixture.source.id, originalExists { return fixture.source }
        if let paired, id == paired.id { return paired }
        throw ResourceError.inaccessibleAsset(id)
    }
    func resources(assetID: String) throws -> [ResourceToken] {
        let value = try source(id: assetID)
        return [value.originalResources.raf] + (value.originalResources.jpeg.map { [$0] } ?? [])
    }
    func changes() -> AsyncStream<LibraryChange> { AsyncStream { $0.finish() } }
    func rawMetadata(_ resource: ResourceToken) -> RAWMetadata { fixture.raw.metadata }
    func materialize(_ resource: ResourceToken, progress: @escaping @Sendable (Double) -> Void) throws -> LocalResource {
        transfers += 1
        let data: Data
        if resource.assetID == fixture.source.id { data = raw }
        else if resource.format == .raf { data = pairRAW ?? Data(); events.append("read-pair-raw") }
        else { data = pairJPEG ?? Data(); events.append("read-pair-jpeg") }
        let url = fixture.root.appendingPathComponent("pair-transfer-\(transfers)")
        try data.write(to: url)
        if fault == "pairChanged", resource.assetID == "paired-asset", resource.format == .jpeg {
            pairState?.modificationDate = Date(timeIntervalSince1970: 300)
        }
        if fault == "originalReordered", resource.assetID == "paired-asset", resource.format == .jpeg {
            originalAlbumPosition = 9
        }
        if fault == "lateOriginalChange", resource.assetID == "paired-asset", resource.format == .jpeg {
            fault = "originalChanged"
        }
        return LocalResource(token: resource, fileURL: url, checksum: try ResourceChecksum.sha256(url))
    }
}
