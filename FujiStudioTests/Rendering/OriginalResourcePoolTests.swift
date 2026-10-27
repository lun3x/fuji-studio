import Foundation
import Testing
@testable import FujiStudio

struct OriginalResourcePoolTests {
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
