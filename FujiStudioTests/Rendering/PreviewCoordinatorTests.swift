import Foundation
import Testing
@testable import FujiStudio

struct PreviewCoordinatorTests {
    @Test func latePreviewCannotReplaceManualOriginalAndKeepsExternalRequestIdentity() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let cache = try f.cache(), latch = RenderLatch(), camera = RenderCamera(f, latch: latch), reader = RenderLibrary(f)
        let coordinator = PreviewCoordinator(pool: reader.pool(), camera: camera, scheduler: ImmediateCameraScheduler(), cache: cache,
            rawRenderer: try RawDisplayRenderer(directory: f.root.appendingPathComponent("display")), storedDisplay: { _,_ in try DisplayFileLease.copy(from: f.raw.fileURL) })
        let request = WorkspacePreviewRequest(generation: 103, sourceID: f.source.id, sourceRevision: f.source.resourceRevision, recipe: f.recipe, cameraContext: f.context)
        var events = await coordinator.events().makeAsyncIterator()
        let pending = Task { await coordinator.request(source: f.source, recipe: f.recipe, workspaceRequest: request) }
        _ = await events.next() // loading
        await latch.entered()
        await coordinator.selectStoredVersion(.cameraJPEG, source: f.source)
        var manual: PreviewEvent?
        while let event = await events.next() { if case .ready = event.state { manual = event; break } }
        #expect(manual?.version == .cameraJPEG)
        await latch.release()
        await pending.value
        #expect(await coordinator.displayedVersion == .cameraJPEG)
        #expect(await cache.lookup(f.key()) != nil)
        #expect(manual?.workspaceRequest == nil)
    }
    @Test func latestRecipeWinsAndReturnsOriginalExternalGenerationNotActorCounter() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let reader = RenderLibrary(f), camera = RenderCamera(f), cache = try f.cache()
        let coordinator = PreviewCoordinator(pool: reader.pool(), camera: camera, scheduler: ImmediateCameraScheduler(), cache: cache, rawRenderer: try RawDisplayRenderer(directory: f.root.appendingPathComponent("display")), storedDisplay: { _,_ in try DisplayFileLease.copy(from: f.raw.fileURL) })
        var events = await coordinator.events().makeAsyncIterator()
        let external = WorkspacePreviewRequest(generation: 78, sourceID: f.source.id, sourceRevision: f.source.resourceRevision, recipe: f.recipe, cameraContext: f.context)
        await coordinator.request(source: f.source, recipe: f.recipe, workspaceRequest: external)
        var ready: PreviewEvent?
        while let e = await events.next() { if case .ready = e.state { ready = e; break } }
        #expect(ready?.workspaceRequest == external)
        #expect(ready?.version == .preview(f.key()))
        #expect(ready?.generation != external.generation)
    }
    @Test func staleExternalContextDoesNotReadCacheOrRender() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let reader = RenderLibrary(f), camera = RenderCamera(f), cache = try f.cache()
        let coordinator = PreviewCoordinator(pool: reader.pool(), camera: camera, scheduler: ImmediateCameraScheduler(), cache: cache, rawRenderer: try RawDisplayRenderer(directory: f.root.appendingPathComponent("display")), storedDisplay: { _,_ in try DisplayFileLease.copy(from: f.raw.fileURL) })
        let newer = CameraExecutionContext(model: f.context.model, firmware: f.context.firmware, capability: f.context.capability, supportVersion: f.context.supportVersion, sessionIdentity: UUID(), generation: 2)
        await camera.changeContext(newer)
        let request = WorkspacePreviewRequest(generation: 9, sourceID: f.source.id, sourceRevision: f.source.resourceRevision, recipe: f.recipe, cameraContext: f.context)
        await coordinator.request(source: f.source, recipe: f.recipe, workspaceRequest: request)
        #expect(await camera.calls == 0)
    }
}

extension PreviewCoordinatorTests {
    @Test func schedulerAdmissionCoalescesLatestSourceAndRecipeBeforeMaterializing() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let reader = RenderLibrary(f), camera = RenderCamera(f), cache = try f.cache()
        let gate = SerialCameraGate(), latch = RenderLatch()
        let holder = Task { try await gate.withExclusiveAccess { await latch.wait() } }
        await latch.entered()
        let coordinator = PreviewCoordinator(pool: reader.pool(), camera: camera, scheduler: GatedCameraScheduler(gate: gate), cache: cache,
            rawRenderer: try RawDisplayRenderer(directory: f.root.appendingPathComponent("display")), storedDisplay: { _,_ in try DisplayFileLease.copy(from: f.raw.fileURL) })
        var events = await coordinator.events().makeAsyncIterator()
        let first = Task { await coordinator.request(source: f.source, recipe: f.recipe) }
        _ = await events.next()
        let newRecipe = f.recipe(named: "Latest", settingsDigest: "latest-settings")
        let second = Task { await coordinator.request(source: f.source, recipe: newRecipe) }
        _ = await events.next()
        let token = ResourceToken(assetID: "second-source", role: .alternateOriginal, contentTypeIdentifier: "com.fuji.raw-image", format: .raf, originalFilename: "second.RAF", discriminator: "second", sourceRevision: "v3")
        let source = PhotoSource(id: "second-source", originalResources: .init(raf: token, jpeg: nil), captureDate: nil, location: nil, resourceRevision: "v3")
        let latest = Task { await coordinator.request(source: source, recipe: newRecipe) }
        _ = await events.next()
        while await gate.queuedOperationCount < 3 { await Task.yield() }
        #expect(await reader.count == 0)
        await latch.release(); try await holder.value
        await first.value; await second.value; await latest.value
        #expect(await reader.count == 1)
        #expect(await camera.calls == 1)
        guard case .preview(let key) = await coordinator.displayedVersion else { Issue.record("Expected latest preview"); return }
        #expect(key.sourceID == "second-source" && key.sourceRevision == "v3" && key.settingsDigest == "latest-settings")
    }

    @Test func renamedSameSettingsReuseKeepsOldRenderProvenanceAndNewRequestLabel() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let reader = RenderLibrary(f), camera = RenderCamera(f), cache = try f.cache()
        let original = try f.jpeg(); try await cache.store(original, key: original.key)
        let renamed = f.recipe(named: "Renamed")
        let coordinator = PreviewCoordinator(pool: reader.pool(), camera: camera, scheduler: ImmediateCameraScheduler(), cache: cache,
            rawRenderer: try RawDisplayRenderer(directory: f.root.appendingPathComponent("display")), storedDisplay: { _,_ in try DisplayFileLease.copy(from: f.raw.fileURL) })
        let request = WorkspacePreviewRequest(generation: 99, sourceID: f.source.id, sourceRevision: f.source.resourceRevision, recipe: renamed, cameraContext: f.context)
        var events = await coordinator.events().makeAsyncIterator()
        await coordinator.request(source: f.source, recipe: renamed, workspaceRequest: request)
        _ = await events.next()
        let ready = await events.next()
        #expect(ready?.workspaceRequest?.recipe.name == "Renamed")
        #expect(ready?.version == .preview(original.key))
        #expect(await cache.lookup(original.key)?.recipeSnapshotID == original.recipeSnapshotID)
        #expect(await camera.calls == 0)
        let changed = f.recipe(named: "Renamed", settingsDigest: "refreshed")
        await coordinator.request(source: f.source, recipe: changed)
        #expect(await camera.calls == 1)
        #expect(await coordinator.displayedVersion != .preview(original.key))
    }

    @Test func rawDisplayFailureRetainsCorrectlyLabelledManualVersionAndSourceConversion() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let reader = RenderLibrary(f), camera = RenderCamera(f), cache = try f.cache()
        let coordinator = PreviewCoordinator(pool: reader.pool(), camera: camera, scheduler: ImmediateCameraScheduler(), cache: cache,
            rawRenderer: try RawDisplayRenderer(directory: f.root.appendingPathComponent("display")), storedDisplay: { _,_ in try DisplayFileLease.copy(from: f.raw.fileURL) })
        await coordinator.request(source: f.source, recipe: f.recipe)
        await coordinator.selectStoredVersion(.cameraJPEG, source: f.source)
        var events = await coordinator.events().makeAsyncIterator()
        await coordinator.selectStoredVersion(.raw, source: f.source)
        _ = await events.next()
        let failed = await events.next()
        #expect(failed?.state == .failed(.rawDisplayUnavailable))
        #expect(failed?.version == .cameraJPEG)
        #expect(await coordinator.displayedVersion == .cameraJPEG)
        await coordinator.request(source: f.source, recipe: f.recipe)
        #expect(await coordinator.displayedVersion == .preview(f.key()))
    }
}

extension PreviewCoordinatorTests {
    @Test func mismatchedCameraResultCannotBeCachedOrDisplayedForRequestedSource() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let reader = RenderLibrary(f), camera = RenderCamera(f), cache = try f.cache()
        let wrong = f.key(hash: "other-source-bytes")
        await camera.overrideResult(wrong)
        let coordinator = PreviewCoordinator(pool: reader.pool(), camera: camera, scheduler: ImmediateCameraScheduler(), cache: cache,
            rawRenderer: try RawDisplayRenderer(directory: f.root.appendingPathComponent("display")), storedDisplay: { _,_ in try DisplayFileLease.copy(from: f.raw.fileURL) })
        await coordinator.request(source: f.source, recipe: f.recipe)
        #expect(await coordinator.displayedVersion == nil)
        #expect(await cache.lookup(wrong) == nil)
    }
}

extension PreviewCoordinatorTests {
    @Test func poolAdmissionSkipsSupersededPreviewBeforeDownloading() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let reader = RenderLibrary(f), gate = SerialCameraGate(), latch = RenderLatch()
        let pool = reader.pool(gate: gate), camera = RenderCamera(f), cache = try f.cache()
        let holder = Task { try await pool.withPreparedRAW(source: f.source) { _ in await latch.wait() } }
        await latch.entered()
        let coordinator = PreviewCoordinator(pool: pool, camera: camera, scheduler: ImmediateCameraScheduler(), cache: cache,
            rawRenderer: try RawDisplayRenderer(directory: f.root.appendingPathComponent("display")), storedDisplay: { _,_ in try DisplayFileLease.copy(from: f.raw.fileURL) })
        let obsolete = Task { await coordinator.request(source: f.source, recipe: f.recipe) }
        while await gate.queuedOperationCount != 1 { await Task.yield() }
        let latest = Task { await coordinator.request(source: f.source, recipe: f.recipe) }
        while await gate.queuedOperationCount != 2 { await Task.yield() }
        #expect(await reader.count == 1)
        await latch.release(); try await holder.value
        await obsolete.value; await latest.value
        #expect(await reader.count == 2) // Held lease plus the latest request; obsolete never downloads.
        #expect(await camera.calls == 1)
        #expect(await coordinator.displayedVersion == .preview(f.key()))
        #expect(await reader.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func manualSelectionSupersedesQueuedLocalRawBeforeDownloading() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let reader = RenderLibrary(f), gate = SerialCameraGate(), latch = RenderLatch()
        let pool = reader.pool(gate: gate), camera = RenderCamera(f), cache = try f.cache()
        let holder = Task { try await pool.withPreparedRAW(source: f.source) { _ in await latch.wait() } }
        await latch.entered()
        let coordinator = PreviewCoordinator(pool: pool, camera: camera, scheduler: ImmediateCameraScheduler(), cache: cache,
            rawRenderer: try RawDisplayRenderer(directory: f.root.appendingPathComponent("display")), storedDisplay: { _,_ in try DisplayFileLease.copy(from: f.raw.fileURL) })
        let raw = Task { await coordinator.request(source: f.source, recipe: nil) }
        while await gate.queuedOperationCount != 1 { await Task.yield() }
        await coordinator.selectStoredVersion(.cameraJPEG, source: f.source)
        await latch.release(); try await holder.value; await raw.value
        #expect(await reader.count == 1) // Manual JPEG selection needs no RAF; queued RAW is obsolete.
        #expect(await camera.calls == 0)
        #expect(await coordinator.displayedVersion == .cameraJPEG)
        #expect(await reader.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
}

extension PreviewCoordinatorTests {
    @Test func readyOwnsSeparateFileAcrossExportAndReleasesStaleBufferedDisplays() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let cache = try f.cache(), reader = RenderLibrary(f), camera = RenderCamera(f)
        let coordinator = PreviewCoordinator(pool: reader.pool(), camera: camera, scheduler: ImmediateCameraScheduler(), cache: cache,
            rawRenderer: try RawDisplayRenderer(directory: f.root.appendingPathComponent("display")), storedDisplay: { _,_ in try DisplayFileLease.copy(from: f.raw.fileURL) })
        var events = await coordinator.events().makeAsyncIterator()
        let request = WorkspacePreviewRequest(generation: 77, sourceID: f.source.id, sourceRevision: f.source.resourceRevision, recipe: f.recipe, cameraContext: f.context)
        await coordinator.request(source: f.source, recipe: f.recipe, workspaceRequest: request)
        _ = await events.next()
        var ready = await events.next()
        let url = try #require(ready?.displayFile?.fileURL)
        #expect(ready?.state == .ready(url))
        #expect(ready?.workspaceRequest == request)
        #expect(ready?.displayFile?.geometry == ImageGeometry(encoded: PixelSize(width: f.key().width, height: f.key().height), orientation: f.key().orientation))
        _ = try await cache.pin(f.key()); await cache.unpin(f.key())
        #expect(FileManager.default.fileExists(atPath: url.path))
        await coordinator.selectStoredVersion(.cameraJPEG, source: f.source)
        #expect(FileManager.default.fileExists(atPath: url.path)) // The consumer still owns it.
        ready = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
        _ = await events.next()
        var second = await events.next()
        let secondURL = try #require(second?.displayFile?.fileURL)
        second = nil
        // Do not drain: only the latest loading/ready pair may retain a display.
        for _ in 0..<5 { await coordinator.selectStoredVersion(.cameraJPEG, source: f.source) }
        #expect(!FileManager.default.fileExists(atPath: secondURL.path))
    }
}
