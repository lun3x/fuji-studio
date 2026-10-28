@testable import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

struct OriginalResourcePoolTests {
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
