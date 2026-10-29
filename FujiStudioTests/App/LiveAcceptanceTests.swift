@testable import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

@MainActor struct LiveAcceptanceTests {
    enum CloseScenario: CaseIterable {
        case confirmed, failedClose, failedCloseInBackground, background, inactive, returnedActive
    }
    @Test(arguments: CloseScenario.allCases)
    func completionRequiresAuthoritativeCloseAndUninterruptedForeground(_ scenario: CloseScenario) async throws {
        let operation = try ProductionOperationFixture(); defer { operation.remove() }
        let fails = scenario == .failedClose || scenario == .failedCloseInBackground
        let wire = ProductionSession(fixture: operation, mode: fails ? .closeFails : .normal)
        let service = FujiCameraService(session: wire, journal: try CameraOperationJournal(directory: operation.directory.appendingPathComponent("journal"), filePolicy: IOSCameraJournalFilePolicy()))
        let fixture = try await FixtureEnvironment.make(cameraOverride: service)
        let model = AppModel(environment: fixture.environment)
        // Keep stream consumption out of this ordering: background itself supplies the UI
        // disconnected reduction, while the real camera service owns the native close result.
        try await service.connect()
        let documents = operation.directory.appendingPathComponent("documents")
        let run = LiveAcceptanceRun(root: documents.appendingPathComponent("live-acceptance-private/runs"), id: UUID())
        #expect(try run.claim())
        try run.write(LiveAcceptanceRunner.Evidence(), name: "evidence.json")
        let revision = model.validationScene.revision, barrier = FixtureBarrier()
        await wire.holdClose(barrier)
        defer { Task { await barrier.release() } }
        let finishing = Task {
            var evidence = LiveAcceptanceRunner.Evidence()
            do {
                try await LiveAcceptanceRunner().finish(model: model, run: run, evidence: &evidence, sceneRevision: revision)
                return false
            } catch { return true }
        }
        try await requireEventually { await wire.closeEntered }
        var background: Task<Void, Never>?
        if scenario == .background || scenario == .failedCloseInBackground {
            background = Task { await model.sceneChanged(.background) }
            try await requireEventually { model.isSuspended }
        } else if scenario == .inactive || scenario == .returnedActive {
            await model.sceneChanged(.inactive)
            if scenario == .returnedActive { await model.sceneChanged(.active) }
        }
        await barrier.release()
        let rejected = await finishing.value
        await background?.value
        var states = await service.states().makeAsyncIterator()
        #expect(await states.next() == (fails ? .recoverableError(.sessionFailure("Native close unconfirmed")) : .disconnected))
        if background != nil { #expect(model.state.cameraState == .disconnected) }
        let saved = try run.read(LiveAcceptanceRunner.Evidence.self, name: "evidence.json")
        let shouldComplete = scenario == .confirmed
        #expect(rejected == !shouldComplete)
        #expect(saved.nativeCloseConfirmed == shouldComplete)
        #expect(saved.complete == shouldComplete)
        let publicURL = documents.appendingPathComponent("live-acceptance-evidence.json")
        if FileManager.default.fileExists(atPath: publicURL.path) {
            let published = try JSONDecoder().decode(LiveAcceptanceRunner.Evidence.self, from: Data(contentsOf: publicURL))
            #expect(published.complete == shouldComplete)
        }
        #expect(await fixture.writer.requests.isEmpty)
    }

    private func requireEventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition(), "Regression fixture did not reach its required ordering point within five seconds")
        try #require(await condition())
    }

    @Test func alreadySatisfiedWaitRejectsSuspension() async throws {
        let fixture = try await FixtureEnvironment.make(), model = AppModel(environment: fixture.environment)
        await model.sceneChanged(.background)
        await #expect(throws: (any Error).self) { try await LiveAcceptanceRunner().wait(model) { true } }
    }

    @Test func claimSurvivesReopenBeforeAnyJobIDAndNeverRearms() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), first = LiveAcceptanceRun(root: root, id: id)
        #expect(try first.claim())
        #expect(FileManager.default.fileExists(atPath: first.directory.path))
        // Simulate death immediately after claiming: no receipt or job ID was written.
        #expect(try !LiveAcceptanceRun(root: root, id: id).claim())
        #expect(try !first.claim())
        #expect(try LiveAcceptanceRun(root: root, id: UUID()).claim())
    }
    @Test func replayWithoutRecordedJobNeverConnectsRendersOrSaves() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        await model.start(automaticallyConnect: false)
        await model.sceneChanged(.active)
        let documents = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: documents) }
        for kind in 0...2 {
            let id = UUID(), run = LiveAcceptanceRun(root: documents.appendingPathComponent("live-acceptance-private/runs"), id: id)
            #expect(try run.claim())
            if kind == 1 { try run.write(LiveAcceptanceRunner.Receipt(runID: id, exportArmed: true), name: "receipt.json") }
            if kind == 2 { try Data("corrupt".utf8).write(to: run.directory.appendingPathComponent("receipt.json")) }
            await LiveAcceptanceRunner().run(model: model, id: id, documents: documents)
            #expect(await f.writer.requests.isEmpty)
            #expect(await f.camera.connectCount == 0)
            #expect(await f.camera.renderCount == 0)
            #expect(try await f.environment.catalog.unfinishedJobs().isEmpty)
        }
    }
    @Test func bankProofRequiresFreshImportFromCurrentSession() async throws {
        let f = try await FixtureEnvironment.make()
        try await f.camera.connect()
        let banks = try await f.camera.importRecipes().recipes, context = try await f.camera.executionContext()
        var state = WorkspaceState()
        state.reduce(.recipesLoaded(banks,slots:RecipeCodecRegistry.xt5Capabilities.bankSlots))
        state.reduce(.cameraChanged(.ready(await f.camera.session), context: context))
        #expect(LiveAcceptanceRunner.banksMatch(state: state, retained: banks))
        state.reduce(.recipeRefreshFailed("synthetic failure"))
        #expect(!LiveAcceptanceRunner.banksMatch(state: state, retained: banks))
        state.reduce(.recipesLoaded(banks,slots:RecipeCodecRegistry.xt5Capabilities.bankSlots))
        try await f.camera.connect()
        state.reduce(.cameraChanged(.ready(await f.camera.session), context: try await f.camera.executionContext()))
        #expect(!LiveAcceptanceRunner.banksMatch(state: state, retained: banks))
    }
    @Test(arguments: [false, true])
    func exactRetainedManifestShapesPreserveHistoricalBinding(_ paired: Bool) throws {
        let f = try RenderFixture(); defer { f.remove() }
        let capture = try RetainedRAWFixture(directory: f.root.appendingPathComponent("retained"), paired: paired)
        let retained = try RetainedProductionAcceptanceInputs.loadSource(root: capture.root, paired: paired)
        let source = Self.liveSource(retained, paired: paired)
        try LiveAcceptanceRunner.validate(source: source, retained: retained, paired: paired)
        for field in ["assetID", "role", "originalFilename", "sourceRevision"] {
            let changed = try Self.changedRAW(source, field: field)
            #expect(throws: ResourceError.resourceChanged) { try LiveAcceptanceRunner.validate(source: changed, retained: retained, paired: paired) }
        }
        if paired {
            let missingPair = PhotoSource(id: source.id, originalResources: .init(raf: source.originalResources.raf, jpeg: nil),
                captureDate: source.captureDate, location: source.location, resourceRevision: source.resourceRevision)
            #expect(throws: ResourceError.resourceChanged) { try LiveAcceptanceRunner.validate(source: missingPair, retained: retained, paired: true) }
            #expect(throws: ResourceError.resourceChanged) {
                try LiveAcceptanceRunner.validate(source: Self.changedRAW(source, field: "discriminator"), retained: retained, paired: true)
            }
            let original = try Data(contentsOf: retained.manifestURL)
            for field in ["rafDiscriminator", "jpegOriginalFilename", "jpegDiscriminator"] {
                for missing in [false, true] {
                    var manifest = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
                    manifest[field] = missing ? nil : "changed"
                    try JSONSerialization.data(withJSONObject: manifest).write(to: retained.manifestURL)
                    #expect(throws: (any Error).self) { try LiveAcceptanceRunner.validate(source: source, retained: retained, paired: true) }
                }
            }
        }
    }

    @Test(arguments: ["unchanged", "discriminator", "assetID", "role", "originalFilename", "sourceRevision", "byteCount"])
    func liveDescriptorChangeDuringMaterializationCannotKeepMatchingBytes(_ field: String) async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let a = try RetainedProductionAcceptanceInputs.loadSource(root: RetainedRAWFixture(directory: f.root.appendingPathComponent("A"), paired: false).root, paired: false)
        let b = try RetainedProductionAcceptanceInputs.loadSource(root: RetainedRAWFixture(directory: f.root.appendingPathComponent("B")).root, paired: true)
        let sourceA = Self.liveSource(a, paired: false), sourceB = Self.liveSource(b, paired: true)
        let changed = field == "unchanged" ? sourceA : try Self.changedRAW(sourceA, field: field)
        let reader = LiveBindingLibrary(a: sourceA, b: sourceB, changedA: changed, root: f.root)
        let runner = LiveAcceptanceRunner()
        if field == "unchanged" {
            let hashes = try await runner.originalHashes(reader: reader, a: sourceA, b: sourceB)
            #expect(hashes.count == 3)
        } else {
            await #expect(throws: ResourceError.resourceChanged) { try await runner.originalHashes(reader: reader, a: sourceA, b: sourceB) }
        }
        #expect(await reader.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    private static func liveSource(_ retained: RetainedRAWSource, paired: Bool) -> PhotoSource {
        let id = retained.raw.sourceID, revision = retained.raw.sourceRevision
        let raw = ResourceToken(assetID: id, role: retained.rafRole, contentTypeIdentifier: "com.fuji.raw-image", format: .raf,
            originalFilename: retained.originalFilename, discriminator: paired ? "paired-raf" : "fresh-live-standalone-raf", sourceRevision: revision)
        let jpeg = paired ? ResourceToken(assetID: id, role: .primaryOriginal, contentTypeIdentifier: "public.jpeg", format: .jpeg,
            originalFilename: "synthetic.JPG", discriminator: "paired-jpeg", sourceRevision: revision) : nil
        return PhotoSource(id: id, originalResources: .init(raf: raw, jpeg: jpeg), captureDate: nil, location: nil, resourceRevision: revision)
    }
    private static func changedRAW(_ source: PhotoSource, field: String) throws -> PhotoSource {
        var value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        var originals = try #require(value["originalResources"] as? [String: Any])
        var raw = try #require(originals["raf"] as? [String: Any])
        raw[field] = field == "role" ? "adjusted" : field == "byteCount" ? 123 : "changed"
        originals["raf"] = raw; value["originalResources"] = originals
        return try JSONDecoder().decode(PhotoSource.self, from: JSONSerialization.data(withJSONObject: value))
    }
    @Test func mixedAndMalformedLiveLaunchNeverReachLiveConstruction() {
        let id = "11111111-1111-1111-1111-111111111111"
        for arguments in [["--live-acceptance-run"], ["--live-acceptance-run", "bad"],
            ["--live-acceptance-run", id, "--ui-fixtures"], ["--live-acceptance-run", id, "--fixture-dark"],
            ["--live-acceptance-run", id, "--xt5-production-acceptance-probe"],
            ["--live-acceptance-run", id, "--live-acceptance-run", id]] {
            #expect(FixtureEnvironment.route(arguments: arguments, unitHost: false) == .invalid)
        }
        #expect(FixtureEnvironment.route(arguments: ["--live-acceptance-run", id], unitHost: true) == .unitHost)
        #expect(FixtureEnvironment.route(arguments: ["--live-acceptance-run", id], unitHost: false) == .liveAcceptance(UUID(uuidString: id)!))
    }
}

/// Changes the live descriptor while returning the originally requested token and valid bytes.
/// The driver must re-read the source, rather than trusting matching payload/checksum alone.
private actor LiveBindingLibrary: PhotoLibraryReading {
    private var a: PhotoSource
    private let b: PhotoSource, changedA: PhotoSource, root: URL
    private(set) var files: [URL] = []
    init(a: PhotoSource, b: PhotoSource, changedA: PhotoSource, root: URL) {
        self.a = a; self.b = b; self.changedA = changedA; self.root = root
    }
    func requestAccess() -> LibraryAccess { .full }
    func sources() -> AsyncThrowingStream<[PhotoSource], Error> { AsyncThrowingStream { $0.yield([a, b]); $0.finish() } }
    func source(id: SourceID) throws -> PhotoSource {
        if id == a.id { return a }; if id == b.id { return b }; throw ResourceError.inaccessibleAsset(id)
    }
    func resources(assetID: String) throws -> [ResourceToken] {
        let source = try source(id: assetID); return [source.originalResources.raf] + (source.originalResources.jpeg.map { [$0] } ?? [])
    }
    func changes() -> AsyncStream<LibraryChange> { AsyncStream { $0.finish() } }
    func rawMetadata(_ resource: ResourceToken) throws -> RAWMetadata { throw ResourceError.invalidRAF("Metadata is unavailable in this fixture") }
    func materialize(_ token: ResourceToken, progress: @escaping @Sendable (Double) -> Void) throws -> LocalResource {
        let file = root.appendingPathComponent("live-transfer-\(UUID().uuidString)")
        try Data("synthetic live payload".utf8).write(to: file); files.append(file)
        if token.assetID == a.id { a = changedA }
        return LocalResource(token: token, fileURL: file, checksum: try ResourceChecksum.sha256(file))
    }
}
