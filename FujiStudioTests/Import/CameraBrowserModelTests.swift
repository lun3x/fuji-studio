import Foundation
import FujiCameraCore
import XCTest

@testable import FujiStudio

@MainActor
final class CameraBrowserModelTests: XCTestCase {
    func testNewestFirstWithNilDatesLastAndStableIdentityTieBreak() async {
        let objects = [
            CaptureFixture.object(1, .raf, stem: "A", date: nil),
            CaptureFixture.object(2, .raf, stem: "B", date: "20261113T180000"),
            CaptureFixture.object(3, .raf, stem: "C"),
            CaptureFixture.object(4, .raf, stem: "D")
        ]
        let session = BrowserSessionFixture(objects: objects)
        let browser = CameraBrowserModel()
        await browser.load(session: session)

        let handles = browser.captures.compactMap { $0.objects.first?.handle }
        XCTAssertEqual(Set(handles.prefix(2)), [3, 4])
        XCTAssertEqual(Array(handles.suffix(2)), [2, 1])
        let tiedIDs = browser.captures.prefix(2).map { $0.id.rawValue }
        XCTAssertEqual(tiedIDs, tiedIDs.sorted())
        await browser.load(session: BrowserSessionFixture(objects: Array(objects.reversed())))
        XCTAssertEqual(browser.captures.compactMap { $0.objects.first?.handle }, handles)
    }

    func testPublishesMetadataWhileCheckingEveryCardAndSerializesThumbnails() async throws {
        let raw = CaptureFixture.object(1, .raf, dimensions: .init(width: 6000, height: 4000))
        let jpeg = CaptureFixture.object(2, .jpeg, storage: 2, dimensions: .init(width: 6000, height: 4000))
        let session = BrowserSessionFixture(batches: [
            .init(objects: [raw], storageChanges: [1: .complete, 2: .pending], rawExposure: .available),
            .init(objects: [jpeg], storageChanges: [2: .complete])
        ], heldBatches: [1])
        let browser = CameraBrowserModel()
        var calls = session.calls.makeAsyncIterator()
        let load = Task { await browser.load(session: session) }
        let firstCall = await calls.next()
        let secondCall = await calls.next()
        XCTAssertEqual(firstCall, .metadata(0))
        XCTAssertEqual(secondCall, .metadata(1))

        let row = try XCTUnwrap(browser.captures.first)
        XCTAssertEqual(row.availability, .checking)
        XCTAssertThrowsError(try browser.select(row.id, policy: .pair))
        XCTAssertThrowsError(try browser.select(row.id, policy: .rawOnly))
        let thumbnail = Task { await browser.thumbnail(for: row) }
        await Task.yield()
        await session.release(batch: 1)
        await load.value
        _ = await thumbnail.value

        XCTAssertEqual(browser.captures.map(\.availability), [.pair])
        let overlapped = await session.overlapCount
        XCTAssertEqual(overlapped, 0)
        let resolved = try XCTUnwrap(browser.captures.first)
        let preview = await browser.thumbnail(for: resolved)
        XCTAssertEqual(preview, Data([2]))
        try browser.select(resolved.id, policy: .pair)
        XCTAssertEqual(browser.selectedCount, 1)
        XCTAssertEqual(browser.knownByteEstimate, 200)
        let chosen = try XCTUnwrap(browser.selectionForImport().first)
        XCTAssertEqual(chosen.descriptors, [raw, jpeg])
        XCTAssertEqual(chosen.camera, CaptureFixture.identity)
        XCTAssertEqual(chosen.policy, .pair)
        let downloads = await session.downloadCount
        XCTAssertEqual(downloads, 0)
    }

    func testProgressivePreviewCanRunBetweenMetadataBatches() async throws {
        let raw = CaptureFixture.object(1, .raf)
        let session = BrowserSessionFixture(batches: [
            .init(objects: [raw], storageChanges: [1: .pending], rawExposure: .available),
            .init(objects: []),
            .init(objects: [], storageChanges: [1: .complete])
        ], heldBatches: [1, 2])
        let browser = CameraBrowserModel()
        var calls = session.calls.makeAsyncIterator()
        let load = Task { await browser.load(session: session) }
        let first = await calls.next()
        let second = await calls.next()
        XCTAssertEqual(first, .metadata(0))
        XCTAssertEqual(second, .metadata(1))

        let checking = try XCTUnwrap(browser.captures.first)
        let (began, request) = AsyncStream<Void>.makeStream()
        let preview = Task {
            request.yield(())
            return await browser.thumbnail(for: checking)
        }
        var awaitingRequest = began.makeAsyncIterator()
        _ = await awaitingRequest.next()
        await session.release(batch: 1)
        let next = await calls.next()
        XCTAssertEqual(next, .thumbnail(1))
        await session.release(batch: 2)
        let data = await preview.value
        await load.value
        XCTAssertEqual(data, Data([1]))
        let overlaps = await session.overlapCount
        XCTAssertEqual(overlaps, 0)
    }

    func testDuplicateBasenamesRequireExplicitRAWOnlyChoiceWithoutDownloading() async throws {
        let raw = CaptureFixture.object(1, .raf, dimensions: .init(width: 6000, height: 4000))
        let browser = CameraBrowserModel()
        let session = BrowserSessionFixture(objects: [
            raw, CaptureFixture.object(2, .jpeg, dimensions: raw.dimensions),
            CaptureFixture.object(3, .jpeg, storage: 2, dimensions: raw.dimensions)
        ])
        await browser.load(session: session)
        let rawCapture = try XCTUnwrap(browser.captures.first { $0.objects.contains(raw) })
        let automaticallyAdmittedPairs = browser.captures.filter { $0.availability == .pair }
        XCTAssertEqual(automaticallyAdmittedPairs.count, 0)
        XCTAssertThrowsError(try browser.select(rawCapture.id, policy: .pair))
        try browser.select(rawCapture.id, policy: .rawOnly)

        XCTAssertEqual(try browser.selectionForImport().first?.policy, .rawOnly)
        XCTAssertEqual(try browser.selectionForImport().first?.descriptors, [raw])
        XCTAssertEqual(browser.selectedCount, 1)
        XCTAssertEqual(browser.knownByteEstimate, 100)
        let fullOriginalDownloadsDuringSelection = await session.downloadCount
        XCTAssertEqual(fullOriginalDownloadsDuringSelection, 0)
    }

    func testJPEGOnlyHEIFAndMoviesAreInformational() async {
        let objects = [
            CaptureFixture.object(1, .jpeg),
            CaptureFixture.object(2, .other(0xb10b)),
            CaptureFixture.object(3, .other(0x300d))
        ]
        let browser = CameraBrowserModel()
        await browser.load(session: BrowserSessionFixture(objects: objects))

        XCTAssertEqual(Set(browser.captures.map(\.availability)), [.jpegOnly, .unsupported])
        for capture in browser.captures {
            XCTAssertThrowsError(try browser.select(capture.id, policy: .pair))
            XCTAssertThrowsError(try browser.select(capture.id, policy: .rawOnly))
        }
        XCTAssertEqual(browser.selectedCount, 0)
    }

    func testSameDescriptiveIDCannotChooseBetweenIndistinguishableRAWs() async throws {
        let browser = CameraBrowserModel()
        await browser.load(session: BrowserSessionFixture(objects: [
            CaptureFixture.object(1, .raf), CaptureFixture.object(2, .raf)
        ]))
        let id = try XCTUnwrap(browser.captures.first?.id)
        XCTAssertThrowsError(try browser.select(id, policy: .rawOnly))
        XCTAssertEqual(browser.selectedCount, 0)
    }

    func testUnverifiedOriginalCapabilityDisablesSelectionAcrossModes() async throws {
        for mode in [WirelessMode.xApp, .phone, .autoSave] {
            let browser = CameraBrowserModel()
            await browser.load(session: BrowserSessionFixture(objects: [
                CaptureFixture.object(1, .raf)
            ], mode: mode, originalSizeVerified: false))

            let capture = try XCTUnwrap(browser.captures.first)
            XCTAssertEqual(capture.availability, .rawOnly)
            XCTAssertFalse(browser.canSelectOriginals)
            XCTAssertThrowsError(try browser.select(capture.id, policy: .rawOnly))
        }
    }

    func testSelectionUsesTheSessionCapabilityAcrossModes() async throws {
        // An explicitly verified fixture describes the generic contract. Production
        // AutoSave does not advertise verified original sizes.
        let browser = CameraBrowserModel()
        let raw = CaptureFixture.object(1, .raf)
        await browser.load(session: BrowserSessionFixture(objects: [raw], mode: .autoSave))
        let capture = try XCTUnwrap(browser.captures.first)
        try browser.select(capture.id, policy: .rawOnly)
        XCTAssertEqual(try browser.selectionForImport().first?.descriptors, [raw])
    }

    func testOriginalEvidenceChangeObservedDuringThumbnailInvalidatesSelection() async throws {
        let raw = CaptureFixture.object(1, .raf)
        let browser = CameraBrowserModel()
        let session = BrowserSessionFixture(objects: [raw], thumbnailFailures: [1: .objectChanged])
        await browser.load(session: session)
        let capture = try XCTUnwrap(browser.captures.first)
        try browser.select(capture.id, policy: .rawOnly)

        let thumbnail = await browser.thumbnail(for: capture)

        XCTAssertNil(thumbnail)
        XCTAssertEqual(browser.failure, .objectChanged)
        XCTAssertThrowsError(try browser.selectionForImport())
        XCTAssertFalse(browser.canSelectOriginals)
    }

    func testReloadDropsSelectionEvenIfIdenticalHandlesAreReused() async throws {
        let browser = CameraBrowserModel()
        let raw = CaptureFixture.object(1, .raf)
        await browser.load(session: BrowserSessionFixture(objects: [raw]))
        let id = try XCTUnwrap(browser.captures.first?.id)
        try browser.select(id, policy: .rawOnly)
        let frozen = try browser.selectionForImport()

        let replacement = CaptureFixture.object(1, .raf, length: 160, session: CaptureFixture.otherSessionID)
        await browser.load(session: BrowserSessionFixture(objects: [replacement]))

        XCTAssertNil(browser.captures.first { $0.id == id })
        XCTAssertThrowsError(try browser.select(id, policy: .rawOnly))
        XCTAssertEqual(browser.selectedCount, 0)
        XCTAssertEqual(try browser.selectionForImport(), [])
        XCTAssertEqual(frozen.first?.descriptors, [raw])
    }

    func testCacheEvictsAt32MiBAndDoesNotReuseBytesAcrossSessions() async throws {
        let first = CaptureFixture.object(1, .raf, stem: "A")
        let second = CaptureFixture.object(2, .raf, stem: "B")
        let session = BrowserSessionFixture(objects: [first, second],
                                           thumbnailSizes: [1: 17 * 1024 * 1024, 2: 16 * 1024 * 1024])
        let browser = CameraBrowserModel()
        await browser.load(session: session)
        let a = try XCTUnwrap(browser.captures.first { $0.objects == [first] })
        let b = try XCTUnwrap(browser.captures.first { $0.objects == [second] })

        let initialA = await browser.thumbnail(for: a)
        let initialB = await browser.thumbnail(for: b)
        let cachedB = await browser.thumbnail(for: b)
        let evictedA = await browser.thumbnail(for: a)
        XCTAssertEqual(initialA?.count, 17 * 1024 * 1024)
        XCTAssertEqual(initialB?.count, 16 * 1024 * 1024)
        XCTAssertEqual(cachedB?.count, 16 * 1024 * 1024)
        XCTAssertEqual(evictedA?.count, 17 * 1024 * 1024)
        let calls = await session.thumbnailCalls
        XCTAssertEqual(calls, [1, 2, 1])

        let reconnected = CaptureFixture.object(1, .raf, stem: "A", session: CaptureFixture.otherSessionID)
        await browser.load(session: BrowserSessionFixture(objects: [reconnected]))
        let newRow = try XCTUnwrap(browser.captures.first)
        let staleThumbnail = await browser.thumbnail(for: a)
        let newThumbnail = await browser.thumbnail(for: newRow)
        XCTAssertEqual(newRow.id, a.id)
        XCTAssertNil(staleThumbnail)
        XCTAssertEqual(newThumbnail, Data([1]))
    }

    func testObsoleteThumbnailCompletionIsDiscardedAndBorrowedSessionIsNotClosed() async throws {
        let session = BrowserSessionFixture(objects: [CaptureFixture.object(1, .raf)], heldThumbnails: [1])
        let browser = CameraBrowserModel()
        await browser.load(session: session)
        let oldCapture = try XCTUnwrap(browser.captures.first)
        var calls = session.calls.makeAsyncIterator()
        let thumbnail = Task { await browser.thumbnail(for: oldCapture) }
        var call = await calls.next()
        while let event = call, event != .thumbnail(1) { call = await calls.next() }
        XCTAssertEqual(call, .thumbnail(1))

        browser.cancel()
        await session.release(thumbnail: 1)
        let obsoleteResult = await thumbnail.value
        let closeCount = await session.closeCount
        XCTAssertNil(obsoleteResult)
        XCTAssertTrue(browser.captures.isEmpty)
        XCTAssertEqual(closeCount, 0)
    }

    func testCanceledQueuedThumbnailNeverStartsOnTheSocket() async throws {
        let raw = CaptureFixture.object(1, .raf, stem: "A")
        let other = CaptureFixture.object(2, .raf, stem: "B")
        let session = BrowserSessionFixture(objects: [raw, other], heldThumbnails: [1])
        let browser = CameraBrowserModel()
        await browser.load(session: session)
        let first = try XCTUnwrap(browser.captures.first { $0.rowID == raw })
        let second = try XCTUnwrap(browser.captures.first { $0.rowID == other })
        var calls = session.calls.makeAsyncIterator()
        let active = Task { await browser.thumbnail(for: first) }
        while let call = await calls.next(), call != .thumbnail(1) {}

        let (began, request) = AsyncStream<Void>.makeStream()
        let queued = Task {
            request.yield(())
            return await browser.thumbnail(for: second)
        }
        var awaitingRequest = began.makeAsyncIterator()
        _ = await awaitingRequest.next()
        queued.cancel()
        await session.release(thumbnail: 1)

        let activeResult = await active.value
        let queuedResult = await queued.value
        let thumbnailCalls = await session.thumbnailCalls
        XCTAssertEqual(activeResult, Data([1]))
        XCTAssertNil(queuedResult)
        XCTAssertEqual(thumbnailCalls, [1])
    }

    func testImportHandoffDrainsRunningThumbnailAndRejectsNewRequests() async throws {
        let session = BrowserSessionFixture(objects: [CaptureFixture.object(1, .raf)], heldThumbnails: [1])
        let browser = CameraBrowserModel()
        await browser.load(session: session)
        let capture = try XCTUnwrap(browser.captures.first)
        var calls = session.calls.makeAsyncIterator()
        let thumbnail = Task { await browser.thumbnail(for: capture) }
        while let call = await calls.next(), call != .thumbnail(1) {}
        try browser.select(capture.id, policy: .rawOnly)
        let release = Task { await session.release(thumbnail: 1) }
        await browser.suspendThumbnails()
        await release.value

        let result = await thumbnail.value
        let suppressed = await browser.thumbnail(for: capture)
        XCTAssertNil(result)
        XCTAssertNil(suppressed)
        XCTAssertEqual(try browser.selectionForImport().first?.captureID, capture.id)
    }

    func testNewLoadCannotBeOverwrittenByCanceledMetadata() async throws {
        let session = BrowserSessionFixture(batches: [
            .init(objects: [CaptureFixture.object(1, .raf)], storageChanges: [1: .complete])
        ], heldBatches: [0])
        let browser = CameraBrowserModel()
        var calls = session.calls.makeAsyncIterator()
        let stale = Task { await browser.load(session: session) }
        let pending = await calls.next()
        XCTAssertEqual(pending, .metadata(0))

        let replacement = CaptureFixture.object(1, .jpeg, session: CaptureFixture.otherSessionID)
        let next = Task { await browser.load(session: BrowserSessionFixture(objects: [replacement])) }
        await session.release(batch: 0)
        await stale.value
        await next.value

        XCTAssertEqual(browser.captures.flatMap(\.objects), [replacement])
    }
}

private actor BrowserSessionFixture: WirelessTransferSession {
    enum Call: Equatable, Sendable {
        case metadata(Int)
        case thumbnail(UInt32)
    }

    nonisolated let calls: AsyncStream<Call>
    private let events: AsyncStream<Call>.Continuation
    private let batches: [WirelessInventoryBatch]
    private let mode: WirelessMode
    private let originalSizeVerified: Bool
    private let thumbnailSizes: [UInt32: Int]
    private let thumbnailFailures: [UInt32: WirelessFailure]
    private var heldBatches: Set<Int>
    private var heldThumbnails: Set<UInt32>
    private var metadataWaits: [Int: CheckedContinuation<Void, Never>] = [:]
    private var thumbnailWaits: [UInt32: CheckedContinuation<Void, Never>] = [:]
    private var cursor = 0
    private var isBusy = false
    private(set) var overlapCount = 0
    private(set) var thumbnailCalls: [UInt32] = []
    private(set) var downloadCount = 0
    private(set) var closeCount = 0

    init(
        batches: [WirelessInventoryBatch], mode: WirelessMode = .xApp, originalSizeVerified: Bool = true,
        heldBatches: Set<Int> = [], thumbnailSizes: [UInt32: Int] = [:], heldThumbnails: Set<UInt32> = [],
        thumbnailFailures: [UInt32: WirelessFailure] = [:]
    ) {
        (calls, events) = AsyncStream.makeStream()
        self.batches = batches
        self.mode = mode
        self.originalSizeVerified = originalSizeVerified
        self.heldBatches = heldBatches
        self.thumbnailSizes = thumbnailSizes
        self.heldThumbnails = heldThumbnails
        self.thumbnailFailures = thumbnailFailures
    }

    init(
        objects: [WirelessObjectDescriptor], mode: WirelessMode = .xApp, originalSizeVerified: Bool = true,
        thumbnailSizes: [UInt32: Int] = [:], heldThumbnails: Set<UInt32> = [],
        thumbnailFailures: [UInt32: WirelessFailure] = [:]
    ) {
        self.init(batches: [.init(objects: objects, storageChanges: [1: .complete, 2: .complete],
                                  rawExposure: .available)], mode: mode, originalSizeVerified: originalSizeVerified,
                  thumbnailSizes: thumbnailSizes, heldThumbnails: heldThumbnails,
                  thumbnailFailures: thumbnailFailures)
    }

    func open() async throws -> WirelessIdentity { CaptureFixture.identity }

    func capabilities() async throws -> WirelessCapabilities {
        .init(mode: mode, rawExposure: .available, storageIDs: [],
              originalSizeVerified: originalSizeVerified, evidenceID: "fixture")
    }

    func enumerate() async throws -> AsyncThrowingStream<WirelessInventoryBatch, Error> {
        cursor = 0
        return AsyncThrowingStream(unfolding: { try await self.nextBatch() })
    }

    func thumbnail(_ object: WirelessObjectDescriptor) async throws -> Data {
        try begin()
        defer { isBusy = false }
        thumbnailCalls.append(object.handle)
        events.yield(.thumbnail(object.handle))
        if heldThumbnails.contains(object.handle) {
            await withCheckedContinuation { thumbnailWaits[object.handle] = $0 }
        }
        if let failure = thumbnailFailures[object.handle] { throw failure }
        return Data(repeating: UInt8(object.handle), count: thumbnailSizes[object.handle] ?? 1)
    }

    func download(
        _ object: WirelessObjectDescriptor, to sink: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        downloadCount += 1
        throw WirelessFailure.unsupportedProtocol
    }

    func close() async throws { closeCount += 1 }

    func release(batch index: Int) {
        heldBatches.remove(index)
        metadataWaits.removeValue(forKey: index)?.resume()
    }

    func release(thumbnail handle: UInt32) {
        heldThumbnails.remove(handle)
        thumbnailWaits.removeValue(forKey: handle)?.resume()
    }

    private func nextBatch() async throws -> WirelessInventoryBatch? {
        guard cursor < batches.count else { return nil }
        try begin()
        defer { isBusy = false }
        let index = cursor
        cursor += 1
        events.yield(.metadata(index))
        if heldBatches.contains(index) {
            await withCheckedContinuation { metadataWaits[index] = $0 }
        }
        return batches[index]
    }

    private func begin() throws {
        if isBusy {
            overlapCount += 1
            throw WirelessFailure.cameraBusy
        }
        isBusy = true
    }
}
