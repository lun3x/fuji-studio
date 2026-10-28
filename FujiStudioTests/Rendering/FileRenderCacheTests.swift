@testable import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

struct FileRenderCacheTests {
    @Test func budgetEvictsOldestUnpinnedButDurablePinSurvivesReopenAndInvalidation() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let cache = try f.cache()
        let a = try f.jpeg(), b = try f.jpeg(key: f.key(hash: "B")), c = try f.jpeg(key: f.key(hash: "C")), d = try f.jpeg(key: f.key(hash: "D"))
        try await cache.store(a, key: a.key)
        let pinned = try await cache.pin(a.key)
        #expect(pinned.path.hasPrefix(f.root.appendingPathComponent("support").path))
        try await cache.store(b, key: b.key); try await cache.store(c, key: c.key); try await cache.store(d, key: d.key)
        #expect(await cache.lookup(b.key) == nil)
        #expect(await cache.lookup(c.key) != nil)
        #expect(await cache.lookup(d.key) != nil)
        #expect(!FileManager.default.fileExists(atPath: a.fileURL.path))
        let reopened = try f.cache()
        #expect(await reopened.lookup(a.key)?.fileURL == pinned)
        await reopened.invalidate(sourceID: f.raw.sourceID)
        #expect(FileManager.default.fileExists(atPath: pinned.path))
        #expect(await reopened.lookup(c.key) == nil)
        await reopened.unpin(a.key)
        #expect(!FileManager.default.fileExists(atPath: pinned.path))
    }
    @Test func partialAndCorruptFilesNeverHitAndWrongKeyCannotStore() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let cache = try f.cache(), jpeg = try f.jpeg()
        await #expect(throws: RenderCacheError.self) { try await cache.store(jpeg, key: f.key(hash: "wrong")) }
        #expect(await cache.lookup(jpeg.key) == nil)
        try await cache.store(jpeg, key: jpeg.key)
        let cached = try #require(await cache.lookup(jpeg.key))
        try Data([0]).write(to: cached.fileURL)
        #expect(await cache.lookup(jpeg.key) == nil)
        let partial = f.root.appendingPathComponent("cache/abandoned.partial")
        try Data([1]).write(to: partial)
        _ = try f.cache()
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }
    @Test func exportRequiresExactSourceContextGeometryAndPreservesRenderProvenance() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let cache = try f.cache(), jpeg = try f.jpeg()
        try await cache.store(jpeg, key: jpeg.key)
        for key in [f.key(hash: "different"), f.key(revision: "v2"), f.key(width: 640), f.key(digest: "new-settings"), f.key(context: .init(model: "X-T5", firmware: "new", capability: f.context.capability, supportVersion: f.context.supportVersion, sessionIdentity: f.context.sessionIdentity, generation: 1))] {
            #expect(await cache.lookup(key) == nil)
        }
        #expect(await cache.lookup(f.key())?.recipeSnapshotID == f.recipe.id)
        let small = try f.jpeg(key: f.key(width: 640))
        try await cache.store(small, key: small.key)
        #expect(await cache.lookup(f.key())?.width == 7728)
    }
}

extension FileRenderCacheTests {
    @Test func productionValidationRejectsUnvalidatedPayloadEvenWhenProvenanceAndHashMatch() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let cache = try FileRenderCache(directory: f.root.appendingPathComponent("strict-cache"), pinnedDirectory: f.root.appendingPathComponent("strict-pins"))
        let jpeg = try f.jpeg()
        await #expect(throws: RenderCacheError.invalidEntry) { try await cache.store(jpeg, key: jpeg.key) }
        #expect(await cache.lookup(jpeg.key) == nil)
    }
}

extension FileRenderCacheTests {
    @Test func cancelledLookupDoesNotEvictValidCachedPixels() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let cache = try f.cache(), jpeg = try f.jpeg()
        try await cache.store(jpeg, key: jpeg.key)
        let latch = RenderLatch()
        let task = Task { await latch.wait(); return await cache.lookup(jpeg.key) }
        await latch.entered(); task.cancel(); await latch.release()
        _ = await task.value
        #expect(await cache.lookup(jpeg.key) != nil)
    }
}

extension FileRenderCacheTests {
    @Test func invalidDurablePinsRemainReservedThroughLookupAndReopenUntilExplicitRelease() async throws {
        // Exercise invalid indexed pixels, lookup dropping the index, and startup losing either
        // pixel or manifest validation. Every occupied durable path still belongs to its journal.
        for scenario in ["pixels-indexed", "pixels-lookup", "pixels-reopen", "manifest-reopen"] {
            let f = try RenderFixture(); defer { f.remove() }
            let cache = try f.cache(), a = try f.jpeg(), b = try f.jpeg(count: 41)
            #expect(a.outputSHA256 != b.outputSHA256 && a.operationID != b.operationID)
            try await cache.store(a, key: a.key)
            let pinned = try await cache.pin(a.key), manifest = pinned.deletingLastPathComponent().appendingPathComponent("entry.json")
            if scenario == "manifest-reopen" { try Data("invalid manifest".utf8).write(to: manifest) }
            else { try Data("invalid pixels".utf8).write(to: pinned) }
            let ownedPixels = try Data(contentsOf: pinned), ownedManifest = try Data(contentsOf: manifest)
            if scenario == "pixels-lookup" { #expect(await cache.lookup(a.key) == nil) }
            let recovering = scenario.hasSuffix("reopen") ? try f.cache() : cache
            if scenario.hasSuffix("reopen") { #expect(await recovering.lookup(a.key) == nil) }
            await recovering.invalidate(sourceID: a.sourceID)
            await #expect(throws: RenderCacheError.pinConflict) { try await recovering.store(b, key: b.key) }
            await #expect(throws: RenderCacheError.pinConflict) { try await recovering.pin(b.key) }
            #expect(try Data(contentsOf: pinned) == ownedPixels)
            #expect(try Data(contentsOf: manifest) == ownedManifest)
            #expect(FileManager.default.fileExists(atPath: b.fileURL.path)) // Refusal transfers no ownership.

            await recovering.unpin(a.key) // Journal owner explicitly releases the invalid reservation.
            #expect(!FileManager.default.fileExists(atPath: pinned.deletingLastPathComponent().path))
            let c = try f.jpeg(count: 42)
            try await recovering.store(c, key: c.key)
            let replacement = try await recovering.pin(c.key)
            #expect(replacement == pinned)
            #expect(try ResourceChecksum.sha256(replacement) == c.outputSHA256)
            #expect(await recovering.lookup(c.key)?.operationID == c.operationID)
        }
    }

    @Test func validDurablePinReuseKeepsOriginalBytesAndProvenance() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let cache = try f.cache(), a = try f.jpeg(), b = try f.jpeg(count: 41)
        try await cache.store(a, key: a.key)
        let pinned = try await cache.pin(a.key), manifest = pinned.deletingLastPathComponent().appendingPathComponent("entry.json")
        let ownedPixels = try Data(contentsOf: pinned), ownedManifest = try Data(contentsOf: manifest)
        let reopened = try f.cache()
        try await reopened.store(b, key: b.key)
        #expect(try await reopened.pin(b.key) == pinned)
        #expect(try Data(contentsOf: pinned) == ownedPixels)
        #expect(try Data(contentsOf: manifest) == ownedManifest)
        #expect(await reopened.lookup(a.key)?.operationID == a.operationID)
        #expect(!FileManager.default.fileExists(atPath: b.fileURL.path))
    }
}
