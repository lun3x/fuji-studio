import Foundation

/// Lazily traverses a capture-date-descending fetch. Only one equal-date group,
/// one lookahead asset, and the current source batch are retained.
struct PhotoSourceDiscovery<Asset> {
    private let count: Int
    private let batchSize: Int
    private let assetAt: (Int) -> Asset
    private let captureDate: (Asset) -> Date?
    private let identifier: (Asset) -> String
    private let source: (Asset) throws -> PhotoSource
    private var fetchIndex = 0
    private var lookahead: Asset?
    private var dateGroup: [Asset] = []
    private var groupIndex = 0

    init(count: Int, batchSize: Int = 64, assetAt: @escaping (Int) -> Asset,
         captureDate: @escaping (Asset) -> Date?, identifier: @escaping (Asset) -> String,
         source: @escaping (Asset) throws -> PhotoSource) {
        precondition(count >= 0 && batchSize > 0)
        self.count = count
        self.batchSize = batchSize
        self.assetAt = assetAt
        self.captureDate = captureDate
        self.identifier = identifier
        self.source = source
    }

    mutating func nextBatch() throws -> [PhotoSource]? {
        try Task.checkCancellation()
        var batch: [PhotoSource] = []
        while batch.count < batchSize, let asset = try nextOrderedAsset() {
            do { batch.append(try source(asset)) }
            catch ResourceError.noOriginalRAF { continue }
        }
        try Task.checkCancellation()
        return batch.isEmpty ? nil : batch
    }

    private mutating func nextOrderedAsset() throws -> Asset? {
        try Task.checkCancellation()
        if groupIndex == dateGroup.count { try loadDateGroup() }
        guard groupIndex < dateGroup.count else { return nil }
        defer { groupIndex += 1 }
        return dateGroup[groupIndex]
    }

    private mutating func loadDateGroup() throws {
        dateGroup.removeAll(keepingCapacity: true)
        groupIndex = 0
        let first: Asset
        if let lookahead {
            first = lookahead
            self.lookahead = nil
        } else if let fetched = try fetchNext() {
            first = fetched
        } else {
            return
        }
        dateGroup.append(first)
        let date = captureDate(first)
        while let next = try fetchNext() {
            guard captureDate(next) == date else { lookahead = next; break }
            dateGroup.append(next)
        }
        let identifier = self.identifier
        dateGroup.sort { identifier($0) < identifier($1) }
    }

    private mutating func fetchNext() throws -> Asset? {
        try Task.checkCancellation()
        guard fetchIndex < count else { return nil }
        defer { fetchIndex += 1 }
        return assetAt(fetchIndex)
    }
}
