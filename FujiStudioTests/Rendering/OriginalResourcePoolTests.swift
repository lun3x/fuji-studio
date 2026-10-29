@testable import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

struct OriginalResourcePoolTests {
    @Test func metadataCachePredatingCaptureDRIsRebuilt() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let directory = f.root.appendingPathComponent("metadata"), reader = RenderLibrary(f)
        let cache = RAWMetadataCache(directory: directory)
        cache.store(f.raw.metadata, for: f.token)
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        var legacy = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        legacy["parserVersion"] = 1
        var metadata = try #require(legacy["metadata"] as? [String: Any])
        metadata.removeValue(forKey: "captureDynamicRange")
        legacy["metadata"] = metadata
        try JSONSerialization.data(withJSONObject: legacy).write(to: file)
        let pool = OriginalResourcePool(reader: reader, metadataCacheDirectory: directory)
        #expect(try await pool.assess(source: f.source, for: fixtureCameraSupport(f.context)) == .supported(model: "X-T5"))
        #expect(await reader.metadataReads == 1)
        #expect(cache.metadata(for: f.token)?.captureDynamicRange == 400)
    }

    @Test func filterAssessmentUsesMetadataWithoutMaterializingOriginal() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let reader = RenderLibrary(f), pool = reader.pool(), support = try fixtureCameraSupport(f.context)
        #expect(try await pool.assess(source: f.source, for: support) == .supported(model: "X-T5"))
        #expect(await reader.metadataReads == 1)
        #expect(await reader.count == 0)
    }

    @Test func recreatedPoolReusesDiskMetadataAndReassessesForAnotherCamera() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let directory = f.root.appendingPathComponent("metadata"), reader = RenderLibrary(f)
        let xt5 = try fixtureCameraSupport(f.context)
        let first = OriginalResourcePool(reader: reader, metadataCacheDirectory: directory)
        #expect(try await first.assess(source: f.source, for: xt5) == .supported(model: "X-T5"))
        let second = OriginalResourcePool(reader: reader, metadataCacheDirectory: directory)
        let xe3 = fixtureCollection([try fixtureXE3Recipe()], slots: [.init(id: 4, label: "C4")]).support
        #expect(try await second.assess(source: f.source, for: xe3) == .incompatible(model: "X-T5"))
        #expect(try await second.assess(source: f.source, for: xt5) == .supported(model: "X-T5"))
        #expect(await second.compatibility(for: f.source) == .supported(model: "X-T5"))
        #expect(await reader.metadataReads == 1)
        #expect(await reader.count == 0)
    }

    @Test func diskCacheInvalidatesChangedRevisionAndOriginalToken() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let directory = f.root.appendingPathComponent("metadata"), reader = RenderLibrary(f), support = try fixtureCameraSupport(f.context)
        _ = try await OriginalResourcePool(reader: reader, metadataCacheDirectory: directory).assess(source: f.source, for: support)
        var token = f.token; token.sourceRevision = "new"
        let revised = PhotoSource(id: f.source.id, originalResources: .init(raf: token), resourceRevision: "new")
        let pool = OriginalResourcePool(reader: reader, metadataCacheDirectory: directory)
        _ = try await pool.assess(source: revised, for: support)
        token = ResourceToken(assetID: token.assetID, role: token.role, contentTypeIdentifier: token.contentTypeIdentifier,
            format: .raf, originalFilename: "replaced.RAF", discriminator: "replacement", sourceRevision: "new")
        let replaced = PhotoSource(id: revised.id, originalResources: .init(raf: token), resourceRevision: "new")
        _ = try await pool.assess(source: replaced, for: support)
        #expect(await reader.metadataReads == 3)
        #expect(await reader.count == 0)
    }

    @Test(arguments: [false, true]) func corruptOrMissingCacheIsRebuilt(_ remove: Bool) async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let directory = f.root.appendingPathComponent("metadata"), reader = RenderLibrary(f), support = try fixtureCameraSupport(f.context)
        _ = try await OriginalResourcePool(reader: reader, metadataCacheDirectory: directory).assess(source: f.source, for: support)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let file = try #require(files.first)
        if remove { try FileManager.default.removeItem(at: file) }
        else { try Data("incomplete JSON".utf8).write(to: file) }
        #expect(try await OriginalResourcePool(reader: reader, metadataCacheDirectory: directory).assess(source: f.source, for: support) == .supported(model: "X-T5"))
        #expect(await reader.metadataReads == 2)
    }

    @Test func unavailableCacheStorageDoesNotPreventAssessment() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let directory = f.root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: directory)
        let reader = RenderLibrary(f), support = try fixtureCameraSupport(f.context)
        #expect(try await OriginalResourcePool(reader: reader, metadataCacheDirectory: directory).assess(source: f.source, for: support) == .supported(model: "X-T5"))
        #expect(await reader.metadataReads == 1)
        #expect(await reader.count == 0)
    }

    @Test func transientMetadataFailureDoesNotPoisonPersistentCache() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let directory = f.root.appendingPathComponent("metadata"), reader = RenderLibrary(f), support = try fixtureCameraSupport(f.context)
        let pool = OriginalResourcePool(reader: reader, metadataCacheDirectory: directory)
        await reader.failMetadata(.retrievalFailed("offline"))
        await #expect(throws: ResourceError.retrievalFailed("offline")) { try await pool.assess(source: f.source, for: support) }
        await reader.failMetadata(nil)
        #expect(try await pool.assess(source: f.source, for: support) == .supported(model: "X-T5"))
        _ = try await OriginalResourcePool(reader: reader, metadataCacheDirectory: directory).assess(source: f.source, for: support)
        #expect(await reader.metadataReads == 2)
    }

    @Test func fullPreparationSeedsPersistentMetadata() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let directory = f.root.appendingPathComponent("metadata"), reader = RenderLibrary(f), support = try fixtureCameraSupport(f.context)
        _ = try await reader.pool(metadataCacheDirectory: directory).withPreparedRAW(source: f.source) { $0.metadata }
        #expect(try await OriginalResourcePool(reader: reader, metadataCacheDirectory: directory).assess(source: f.source, for: support) == .supported(model: "X-T5"))
        #expect(await reader.metadataReads == 0)
        #expect(await reader.count == 1)
    }

    @Test func assessmentsReuseMetadataWithoutPoisoningOtherCameras() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let reader = RenderLibrary(f), pool = reader.pool()
        let xt5 = try fixtureCameraSupport(f.context)
        let xe3 = fixtureCollection([try fixtureXE3Recipe()], slots: [.init(id: 4, label: "C4")]).support
        #expect(try await pool.assess(source: f.source, for: xe3) == .incompatible(model: "X-T5"))
        #expect(await pool.compatibility(for: f.source) == .supported(model: "X-T5"))
        #expect(try await pool.assess(source: f.source, for: xt5) == .supported(model: "X-T5"))
        #expect(try await pool.assess(source: f.source, for: xt5) == .supported(model: "X-T5"))
        #expect(await reader.count == 0)
        #expect(await reader.metadataReads == 1)
        #expect(await reader.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func matchingModelWithUnsupportedGeometryStaysExcluded() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let reader = RenderLibrary(f)
        await reader.setMetadata(.init(cameraModel: "X-E3",
                containerGeometry: .init(width: 6048, height: 4038), recordedGeometry: .init(width: 3000, height: 2000),
                recordedAspect: .init(width: 3, height: 2), cropTop: 21, cropLeft: 16, orientation: 1,
                compression: .lossless, bitDepth: 14, rafVersion: "0130"))
        let pool = OriginalResourcePool(reader: reader)
        let support = fixtureCollection([try fixtureXE3Recipe()], slots: [.init(id: 4, label: "C4")]).support
        #expect(try await pool.assess(source: f.source, for: support) == .incompatible(model: "X-E3"))
        #expect(await pool.compatibility(for: f.source) == .supported(model: "X-E3"))
    }

    @Test func assessmentCacheIsBoundToOriginalRevision() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let reader = RenderLibrary(f), pool = reader.pool(), support = try fixtureCameraSupport(f.context)
        _ = try await pool.assess(source: f.source, for: support)
        var token = f.token; token.sourceRevision = "revised"
        let revised = PhotoSource(id: f.source.id, originalResources: .init(raf: token), resourceRevision: "revised")
        _ = try await pool.assess(source: revised, for: support)
        #expect(await reader.count == 0)
        #expect(await reader.metadataReads == 2)
    }

    @Test func decodeFailureDoesNotRevokeCameraConversion() async throws {
        let f=try RenderFixture();defer { f.remove() }
        let reader=RenderLibrary(f)
        let pool=OriginalResourcePool(reader:reader,prepare:{ local in
            PreparedRAW(fileURL:local.fileURL,sha256:local.checksum,sourceID:local.token.assetID,sourceRevision:local.token.sourceRevision,
                metadata:.init(cameraModel:"X-E3",containerGeometry:.init(width:6160,height:4032),recordedGeometry:.init(width:6000,height:4000),recordedAspect:.init(width:3,height:2),cropTop:16,cropLeft:16,orientation:1,compression:.uncompressed,bitDepth:14,rafVersion:"0130"))
        })
        let renderer=try RawDisplayRenderer(directory:f.root.appendingPathComponent("xe3-display"))
        await #expect(throws:RawDisplayError.unavailable) { try await pool.withPreparedRAW(source:f.source) { try await renderer.render($0) } }
        #expect(await pool.compatibility(for:f.source) == .supported(model:"X-E3"))
        let recipe=try fixtureXE3Recipe(),receipt=fixtureCollection([recipe],slots:[.init(id:4,label:"C4")])
        let support=receipt.support
        let compatibility=try await pool.withPreparedRAW(source:f.source) { raw in SourceCompatibility.assess(raw.metadata,for:support) }
        #expect(compatibility == .supported(model:"X-E3"))
    }
    @Test func waitingLeaseDoesNotMaterializeAndCleanupSpansSuspendedUse() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let reader = RenderLibrary(f), gate = SerialCameraGate(), latch = RenderLatch()
        let pool = reader.pool(gate: gate)
        let first = Task { try await pool.withPreparedRAW(source: f.source) { raw in await latch.wait(); return raw.fileURL } }
        await latch.entered()
        let second = Task { try await pool.withPreparedRAW(source: f.source) { $0.fileURL } }
        while await gate.queuedOperationCount == 0 { await Task.yield() }
        #expect(await reader.count == 1)
        #expect(await reader.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        await latch.release()
        let urls = try await [first.value, second.value]
        #expect(urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(await reader.count == 2)
    }
    @Test func cancelledWaiterNeverDownloadsAndThrowingUseReleasesLease() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let reader = RenderLibrary(f), gate = SerialCameraGate(), latch = RenderLatch(), pool = reader.pool(gate: gate)
        let first = Task { try await pool.withPreparedRAW(source: f.source) { _ -> URL in await latch.wait(); throw ResourceError.invalidRAF("synthetic") } }
        await latch.entered()
        let second = Task { try await pool.withPreparedRAW(source: f.source) { $0.fileURL } }
        while await gate.queuedOperationCount == 0 { await Task.yield() }; second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        await latch.release(); await #expect(throws: ResourceError.self) { try await first.value }
        _ = try await pool.withPreparedRAW(source: f.source) { $0.fileURL }
        #expect(await reader.count == 2)
        #expect(await reader.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
    @Test func realDecoderFailureDoesNotRemoveSourceOrDisableCameraPreparation() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let reader = RenderLibrary(f), pool = reader.pool(), renderer = try RawDisplayRenderer(directory: f.root.appendingPathComponent("display"))
        await #expect(throws: RawDisplayError.self) { try await pool.withPreparedRAW(source: f.source) { try await renderer.render($0) } }
        let id = try await pool.withPreparedRAW(source: f.source) { $0.sourceID }
        #expect(id == f.source.id)
        #expect(await reader.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
}

extension OriginalResourcePoolTests {
    @Test func localRawDisplayWaitsBehindBatchLeaseAndInvalidZoomDoesNotDecode() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let reader = RenderLibrary(f), gate = SerialCameraGate(), pool = reader.pool(gate: gate), latch = RenderLatch()
        let renderer = try RawDisplayRenderer(directory: f.root.appendingPathComponent("display"))
        let batch = Task { try await pool.withPreparedRAW(source: f.source) { _ in await latch.wait() } }
        await latch.entered()
        let display = Task { try await pool.withPreparedRAW(source: f.source) { try await renderer.render($0) } }
        while await gate.queuedOperationCount == 0 { await Task.yield() }
        #expect(await reader.count == 1)
        await latch.release(); try await batch.value
        await #expect(throws: RawDisplayError.unavailable) { try await display.value }
        #expect(await reader.count == 2)
        await #expect(throws: RawDisplayError.invalidDetail) { try await renderer.renderDetail(f.raw, region: CGRect(x: -1, y: 0, width: 1, height: 1), maximumDimension: 2048) }
    }
}
