import UIKit

struct GridMetrics: Equatable {
    let columns: Int
    let tileWidth: CGFloat
    var tileHeight: CGFloat { tileWidth }
    let spacing: CGFloat
    let insets: UIEdgeInsets
    func contentRows(itemCount: Int) -> Int { (max(0, itemCount) + columns - 1) / columns }
    func height(rows: Int) -> CGFloat { insets.top + insets.bottom + CGFloat(max(0, rows)) * tileWidth + CGFloat(max(0, rows - 1)) * spacing }
    func rect(index: Int) -> CGRect {
        CGRect(x: insets.left + CGFloat(index % columns) * (tileWidth + spacing),
               y: insets.top + CGFloat(index / columns) * (tileWidth + spacing), width: tileWidth, height: tileWidth)
    }
    /// Clamps gaps/edge fingers to the nearest tile; supports recomputation during autoscroll.
    func index(at point: CGPoint, itemCount: Int) -> Int? {
        guard itemCount > 0 else { return nil }
        let col = min(columns - 1, max(0, Int((point.x - insets.left) / (tileWidth + spacing))))
        let row = max(0, Int((point.y - insets.top) / (tileWidth + spacing)))
        return min(itemCount - 1, row * columns + col)
    }
    func offsetToReveal(index: Int, viewportHeight: CGFloat, currentOffset: CGFloat, itemCount: Int) -> CGFloat {
        let r = rect(index: index)
        let needed = r.minY < currentOffset ? r.minY : r.maxY > currentOffset + viewportHeight ? r.maxY - viewportHeight : currentOffset
        return min(max(0, height(rows: contentRows(itemCount: itemCount)) - viewportHeight), max(0, needed))
    }
}

enum GridGeometry {
    static func metrics(width: CGFloat, preferredTile: CGFloat = 100, spacing: CGFloat = 3, insets: UIEdgeInsets = .init(top: 8, left: 8, bottom: 8, right: 8)) -> GridMetrics {
        let available = max(1, width - insets.left - insets.right)
        let gap = max(0, spacing)
        let columns = max(1, Int((available + gap) / (max(1, preferredTile) + gap)))
        return GridMetrics(columns: columns, tileWidth: (available - CGFloat(columns - 1) * gap) / CGFloat(columns), spacing: gap, insets: insets)
    }
}
