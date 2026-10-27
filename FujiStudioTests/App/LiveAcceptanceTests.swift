import Foundation
import Testing
@testable import FujiStudio

@MainActor struct LiveAcceptanceTests {
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
        await model.start()
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
        await f.camera.connect()
        let banks = try await f.camera.importRecipes(), context = try await f.camera.executionContext()
        var state = WorkspaceState()
        state.reduce(.recipesRefreshed(banks))
        state.reduce(.cameraChanged(.ready(await f.camera.session), context: context))
        #expect(LiveAcceptanceRunner.banksMatch(state: state, retained: banks))
        state.reduce(.recipeRefreshFailed("synthetic failure"))
        #expect(!LiveAcceptanceRunner.banksMatch(state: state, retained: banks))
        state.reduce(.recipesRefreshed(banks))
        await f.camera.connect()
        state.reduce(.cameraChanged(.ready(await f.camera.session), context: try await f.camera.executionContext()))
        #expect(!LiveAcceptanceRunner.banksMatch(state: state, retained: banks))
    }
    @Test func strictBindingRejectsChangedDiscriminatorAndPairedJPEGFilename() throws {
        let f = try RenderFixture(); defer { f.remove() }
        let manifest = f.root.appendingPathComponent("manifest.json")
        let jpeg = ResourceToken(assetID: f.source.id, role: .alternateOriginal, contentTypeIdentifier: "public.jpeg", format: .jpeg,
            originalFilename: "paired.JPG", discriminator: "jpeg-original", sourceRevision: f.source.resourceRevision)
        try JSONSerialization.data(withJSONObject: ["rafDiscriminator": f.token.discriminator, "jpegOriginalFilename": "paired.JPG", "jpegDiscriminator": "jpeg-original"])
            .write(to: manifest)
        let retained = RetainedRAWSource(raw: f.raw, rafRole: .primaryOriginal, jpegRole: .alternateOriginal,
            originalFilename: f.token.originalFilename, manifestURL: manifest, protocolURL: manifest)
        func source(_ raw: ResourceToken, _ jpeg: ResourceToken?) -> PhotoSource {
            PhotoSource(id: f.source.id, originalResources: .init(raf: raw, jpeg: jpeg), captureDate: nil, location: nil, resourceRevision: f.source.resourceRevision)
        }
        try LiveAcceptanceRunner.validate(source: source(f.token, jpeg), retained: retained, paired: true)
        let wrongRAW = ResourceToken(assetID: f.token.assetID, role: f.token.role, contentTypeIdentifier: f.token.contentTypeIdentifier,
            format: f.token.format, originalFilename: f.token.originalFilename, discriminator: "changed", sourceRevision: f.token.sourceRevision)
        #expect(throws: (any Error).self) { try LiveAcceptanceRunner.validate(source: source(wrongRAW, jpeg), retained: retained, paired: true) }
        let wrongJPEG = ResourceToken(assetID: jpeg.assetID, role: jpeg.role, contentTypeIdentifier: jpeg.contentTypeIdentifier,
            format: jpeg.format, originalFilename: "changed.JPG", discriminator: jpeg.discriminator, sourceRevision: jpeg.sourceRevision)
        #expect(throws: (any Error).self) { try LiveAcceptanceRunner.validate(source: source(f.token, wrongJPEG), retained: retained, paired: true) }
        #expect(throws: (any Error).self) { try LiveAcceptanceRunner.validate(source: source(f.token, nil), retained: retained, paired: true) }
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
