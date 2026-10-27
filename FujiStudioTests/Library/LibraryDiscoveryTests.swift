import Foundation
import Testing
import Photos
@testable import FujiStudio

struct LibraryDiscoveryTests {
    @Test func cancellationAfterInitialBatchCannotReturnPartialDiscovery() async throws {
        let (waitingForNextBatch, signal) = AsyncStream<Void>.makeStream()
        let feed = SuspendedBatchFeed(first: [try makeSource(TestAsset("first", 3))], signal: signal)
        let stream = AsyncThrowingStream<[PhotoSource], Error>(unfolding: { await feed.next() })
        let reader = DiscoveryReader(stream: stream)
        let task = Task { try await reader.allEligibleSources() }
        // The feed signals only when the collector asks for its second batch.
        for await _ in waitingForNextBatch { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func alreadyCancelledDiscoveryDoesNotStartLibraryAccess() async throws {
        let reader = DiscoveryReader(stream: AsyncThrowingStream { $0.finish() })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.allEligibleSources()
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await reader.discoveryRequests == 0)
    }

    @Test func firstBatchDoesNotEnumerateTheEntireFetch() throws {
        let assets = [TestAsset("newest", 6), TestAsset("second", 5), TestAsset("third", 4),
                      TestAsset("fourth", 3), TestAsset("fifth", 2), TestAsset("oldest", 1)]
        var reads: [Int] = []
        var inspected: [String] = []
        var discovery = PhotoSourceDiscovery(count: assets.count, batchSize: 2, assetAt: {
            reads.append($0)
            return assets[$0]
        }, captureDate: { $0.date }, identifier: { $0.id }, source: {
            inspected.append($0.id)
            return try makeSource($0)
        })
        let next = try discovery.nextBatch()
        let first = try #require(next)
        #expect(first.map(\.id) == ["newest", "second"])
        #expect(reads.count <= 3) // At most one lookahead to close the equal-date group.
        #expect(inspected == ["newest", "second"])
    }

    @Test func equalDateGroupsAreOrderedByIDAcrossBatchesAndMissingDatesAreLast() throws {
        let assets = [TestAsset("c", 3), TestAsset("a", 3), TestAsset("b", 3),
                      TestAsset("jpeg-only", 2, hasRAF: false), TestAsset("d", 1),
                      TestAsset("nil-b", nil), TestAsset("nil-a", nil)]
        var discovery = PhotoSourceDiscovery(count: assets.count, batchSize: 2, assetAt: { assets[$0] },
                                             captureDate: { $0.date }, identifier: { $0.id }, source: makeSource)
        var batches: [[PhotoSource]] = []
        while let batch = try discovery.nextBatch() { batches.append(batch) }
        #expect(batches.map { $0.map(\.id) } == [["a", "b"], ["c", "d"], ["nil-a", "nil-b"]])
        #expect(batches.flatMap { $0 }.allSatisfy { $0.originalResources.raf.assetID == $0.id })
    }

    @Test func completeDiscoveryCollectsEveryBatch() async throws {
        let first = try makeSource(TestAsset("first", 3))
        let last = try makeSource(TestAsset("last", 1))
        let stream = AsyncThrowingStream<[PhotoSource], Error> {
            $0.yield([first])
            $0.yield([last])
            $0.finish()
        }
        let result = try await DiscoveryReader(stream: stream).allEligibleSources()
        #expect(result.map(\.id) == ["first", "last"])
    }
}

private struct TestAsset {
    let id: String
    let date: Date?
    let hasRAF: Bool
    init(_ id: String, _ timestamp: TimeInterval?, hasRAF: Bool = true) {
        self.id = id
        date = timestamp.map(Date.init(timeIntervalSince1970:))
        self.hasRAF = hasRAF
    }
}

private func makeSource(_ asset: TestAsset) throws -> PhotoSource {
    let jpeg = PhotoResourceDescriptor(assetID: asset.id, resourceType: PHAssetResourceType.photo.rawValue,
                                       contentTypeIdentifier: "public.jpeg", filename: "original.JPG").token
    var tokens = [jpeg]
    if asset.hasRAF {
        tokens.append(PhotoResourceDescriptor(assetID: asset.id, resourceType: PHAssetResourceType.alternatePhoto.rawValue,
                                             contentTypeIdentifier: "com.fuji.raw-image", filename: "original.RAF").token)
    }
    return PhotoSource(id: asset.id, originalResources: try RawResourceSelector.select(tokens),
                       captureDate: asset.date, location: nil, resourceRevision: "fixture")
}

private actor SuspendedBatchFeed {
    let first: [PhotoSource]
    let signal: AsyncStream<Void>.Continuation
    let parked: AsyncStream<Void>
    let parkingContinuation: AsyncStream<Void>.Continuation
    var requestedFirst = false

    init(first: [PhotoSource], signal: AsyncStream<Void>.Continuation) {
        self.first = first
        self.signal = signal
        (parked, parkingContinuation) = AsyncStream<Void>.makeStream()
    }

    func next() async -> [PhotoSource]? {
        if !requestedFirst { requestedFirst = true; return first }
        signal.yield(())
        signal.finish()
        for await _ in parked { }
        return nil
    }
}

/// Only the external batch producer is substituted; collection uses the real protocol implementation.
private actor DiscoveryReader: PhotoLibraryReading {
    let stream: AsyncThrowingStream<[PhotoSource], Error>
    var discoveryRequests = 0
    init(stream: AsyncThrowingStream<[PhotoSource], Error>) { self.stream = stream }
    func sources() async -> AsyncThrowingStream<[PhotoSource], Error> {
        discoveryRequests += 1
        return stream
    }
    func requestAccess() async -> LibraryAccess { .full }
    func source(id: SourceID) async throws -> PhotoSource { throw ResourceError.inaccessibleAsset(id) }
    func resources(assetID: String) async throws -> [ResourceToken] { throw ResourceError.inaccessibleAsset(assetID) }
    func changes() async -> AsyncStream<LibraryChange> { AsyncStream { $0.finish() } }
    func materialize(_ resource: ResourceToken, progress: @escaping @Sendable (Double) -> Void) async throws -> LocalResource {
        throw ResourceError.resourceChanged
    }
}
