import Foundation
import Testing
import Photos
@testable import FujiStudio

struct LibraryDiscoveryTests {
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

