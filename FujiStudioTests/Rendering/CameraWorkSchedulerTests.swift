@testable import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

struct CameraWorkSchedulerTests {
    @Test func admitsOwnedExportItem() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let scheduler = CameraWorkScheduler(), job = UUID()
        try await scheduler.beginExport(jobID: job)
        let jpeg = try await scheduler.withExportItem(jobID: job) { try f.jpeg() }
        #expect(jpeg.sourceID == f.source.id)
        await scheduler.endExport(jobID: job)
    }
    @Test func exportDrainsPreviewAndCoalescesDeferredWork() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let scheduler = CameraWorkScheduler(), active = RenderLatch(), trace = ExportTrace()
        let preview = Task { try await scheduler.withPreview { await trace.add("preview"); await active.wait(); return try f.jpeg() } }
        await active.entered()
        let job = UUID()
        let begin = Task { try await scheduler.beginExport(jobID: job) }
        // Wait for actor admission, without releasing the in-flight camera operation.
        while await scheduler.exportJobID != job { await Task.yield() }
        let old = Task { try await scheduler.withPreview { await trace.add("obsolete"); return try f.jpeg() } }
        while await scheduler.hasDeferredPreview == false { await Task.yield() }
        let latest = Task { try await scheduler.withPreview { await trace.add("latest"); return try f.jpeg() } }
        do { _ = try await old.value; Issue.record("Superseded preview ran") } catch is CancellationError {}
        #expect(await trace.values == ["preview"])
        await active.release(); _ = try await preview.value; try await begin.value
        _ = try await scheduler.withExportItem(jobID: job) { await trace.add("export"); return try f.jpeg() }
        #expect(await trace.values == ["preview", "latest", "export"])
        await scheduler.endExport(jobID: job); _ = try await latest.value
        #expect(await trace.values == ["preview", "latest", "export"])
    }

    @Test func newestPreviewRunsAfterActiveExportBeforeNextItem() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let scheduler = CameraWorkScheduler(), active = RenderLatch(), trace = ExportTrace(), job = UUID()
        try await scheduler.beginExport(jobID: job)
        let first = Task {
            try await scheduler.withExportItem(jobID: job) {
                await trace.add("first export")
                await active.wait()
                await trace.add("first finished")
                return try f.jpeg()
            }
        }
        await active.entered()
        let old = Task { try await scheduler.withPreview { await trace.add("obsolete"); return try f.jpeg() } }
        while await !scheduler.hasDeferredPreview { await Task.yield() }
        let latest = Task { try await scheduler.withPreview { await trace.add("latest preview"); return try f.jpeg() } }
        do { _ = try await old.value; Issue.record("Superseded preview ran") } catch is CancellationError {}
        let next = Task { try await scheduler.withExportItem(jobID: job) { await trace.add("next export"); return try f.jpeg() } }
        #expect(await trace.values == ["first export"])
        await active.release(); _ = try await first.value; _ = try await next.value
        #expect(await trace.values == ["first export", "first finished", "latest preview", "next export"])
        #expect(await scheduler.exportJobID == job)
        await scheduler.endExport(jobID: job); _ = try await latest.value
    }

    @Test func cancelledQueuedPreviewDoesNotBlockNextExport() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let scheduler = CameraWorkScheduler(), active = RenderLatch(), trace = ExportTrace(), job = UUID()
        try await scheduler.beginExport(jobID: job)
        let first = Task { try await scheduler.withExportItem(jobID: job) { await active.wait(); return try f.jpeg() } }
        await active.entered()
        let preview = Task { try await scheduler.withPreview { await trace.add("cancelled preview"); return try f.jpeg() } }
        while await !scheduler.hasDeferredPreview { await Task.yield() }
        preview.cancel()
        do { _ = try await preview.value; Issue.record("Cancelled preview ran") } catch is CancellationError {}
        await active.release(); _ = try await first.value
        _ = try await scheduler.withExportItem(jobID: job) { await trace.add("next export"); return try f.jpeg() }
        #expect(await trace.values == ["next export"])
        await scheduler.endExport(jobID: job)
    }

    @Test func cancelledAdmissionDoesNotRunAndReleasesPriority() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let scheduler = CameraWorkScheduler(), active = RenderLatch(), trace = ExportTrace()
        let preview = Task { try await scheduler.withPreview { await active.wait(); return try f.jpeg() } }
        await active.entered()
        let job = UUID(), begin = Task { try await scheduler.beginExport(jobID: job) }
        while await scheduler.exportJobID != job { await Task.yield() }
        begin.cancel()
        do { try await begin.value; Issue.record("Cancelled admission succeeded") } catch is CancellationError {}
        await active.release(); _ = try await preview.value
        _ = try await scheduler.withPreview { await trace.add("released"); return try f.jpeg() }
        #expect(await trace.values == ["released"])
    }
}

actor ExportTrace {
    var values: [String] = []
    func add(_ value: String) { values.append(value) }
}
