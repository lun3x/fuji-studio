import FujiCameraCore
import Foundation

/// A sweep always derives membership from the immutable starting snapshot.
struct RangeSelection {
    private var starting: Set<SourceID> = []
    private var orderedIDs: [SourceID] = []
    private var origin = 0
    private var removes = false
    mutating func begin(index: Int, checked: Set<SourceID>, orderedIDs: [SourceID]) {
        starting = checked; self.orderedIDs = orderedIDs
        origin = min(max(0, index), max(0, orderedIDs.count - 1))
        removes = !orderedIDs.isEmpty && checked.contains(orderedIDs[origin])
    }
    func update(index: Int) -> Set<SourceID> {
        guard !orderedIDs.isEmpty else { return starting }
        let end = min(max(0, index), orderedIDs.count - 1)
        let range = Set(orderedIDs[min(origin, end)...max(origin, end)])
        return removes ? starting.subtracting(range) : starting.union(range)
    }
    func cancel() -> Set<SourceID> { starting }
}
