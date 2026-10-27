import Testing
import UIKit
@testable import FujiStudio

struct GridGeometryTests {
    @Test func squareRowsAndTwoRowViewport() {
        let m = GridGeometry.metrics(width: 390, preferredTile: 100, spacing: 3, insets: .init(top: 8, left: 12, bottom: 8, right: 12))
        #expect(m.columns == 3)
        #expect(m.tileWidth == 120)
        #expect(m.tileHeight == 120)
        #expect(m.contentRows(itemCount: 1000) == 334)
        #expect(m.height(rows: 2) == 259)
        let rows = (0..<334).map { m.rect(index: $0 * 3) }
        #expect(zip(rows, rows.dropFirst()).allSatisfy { $0.maxY < $1.minY })
        #expect(m.index(at: CGPoint(x: 20, y: 380), itemCount: 1000) == 9)
    }
    @Test func narrowWidthsStillProduceOneSquare() {
        let m = GridGeometry.metrics(width: 50, preferredTile: 100, spacing: 3, insets: .zero)
        #expect(m.columns == 1); #expect(m.tileWidth == 50)
        #expect(m.contentRows(itemCount: 0) == 0)
    }
    @Test func minimumScrollRespectsFinalViewport() {
        let m = GridGeometry.metrics(width: 390, preferredTile: 100, spacing: 3, insets: .zero)
        #expect(m.offsetToReveal(index: 8, viewportHeight: 259, currentOffset: 0, itemCount: 1000) == 131)
        #expect(m.offsetToReveal(index: 0, viewportHeight: 259, currentOffset: 131, itemCount: 1000) == 0)
    }
}
