import Testing
@testable import FujiStudio

struct RangeSelectionTests {
    let ids = (0..<1000).map { "source-\($0)" }
    @Test func uncheckedStartAddsAndReversalRestoresUntouchedMembership() {
        var range = RangeSelection()
        range.begin(index: 3, checked: ["source-1", "source-8"], orderedIDs: ids)
        #expect(range.update(index: 7) == Set([1,3,4,5,6,7,8].map { "source-\($0)" }))
        #expect(range.update(index: 4) == ["source-1", "source-3", "source-4", "source-8"])
        #expect(range.cancel() == ["source-1", "source-8"])
    }
    @Test func checkedStartRemovesAndCancelRestoresStartingSelection() {
        var range = RangeSelection()
        range.begin(index: 4, checked: Set((1...8).map { "source-\($0)" }), orderedIDs: ids)
        #expect(range.update(index: 7) == Set([1,2,3,8].map { "source-\($0)" }))
        #expect(range.update(index: 2) == Set([1,5,6,7,8].map { "source-\($0)" }))
        #expect(range.cancel() == Set((1...8).map { "source-\($0)" }))
    }
    @Test func movingFingerAfterEdgeScrollExtendsBeyondInitialCells() {
        var range = RangeSelection()
        range.begin(index: 0, checked: [], orderedIDs: ids)
        #expect(range.update(index: 90).count == 91)
        #expect(range.update(index: 999).count == 1000)
    }
}
