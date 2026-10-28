import SwiftUI

struct DrawerDetents: Equatable {
    let containerHeight: CGFloat
    let collapsedHeight: CGFloat
    let expandedHeight: CGFloat
    let collapsedGridHeight: CGFloat
    var expandedTop: CGFloat { containerHeight - expandedHeight }
    func height(for detent: DrawerDetent) -> CGFloat { detent == .expanded ? expandedHeight : collapsedHeight }
    func clampedHeight(_ height: CGFloat) -> CGFloat { min(expandedHeight, max(collapsedHeight, height)) }
    func destination(height: CGFloat, predictedTranslation: CGFloat) -> DrawerDetent {
        height - predictedTranslation > (collapsedHeight + expandedHeight) / 2 ? .expanded : .collapsed
    }
}

enum DrawerGeometry {
    static let controlClearance: CGFloat = 8
    static func detents(container: CGSize, safeArea: EdgeInsets, headerHeight: CGFloat,
                        grid: GridMetrics, recipeControlFrame: CGRect) -> DrawerDetents {
        let collapsedGrid = grid.height(rows: 1) + safeArea.bottom
        let collapsed = headerHeight + collapsedGrid
        let top = max(safeArea.top, recipeControlFrame.maxY + controlClearance)
        return DrawerDetents(containerHeight: container.height, collapsedHeight: collapsed,
            expandedHeight: max(collapsed, container.height - top), collapsedGridHeight: collapsedGrid)
    }
    /// Keep one complete square row when measured controls leave less room than the preferred tiles.
    /// A single set of metrics is used for both detents and both selection modes.
    static func gridMetrics(width: CGFloat, availableGridHeight: CGFloat) -> GridMetrics {
        // Give the side margins to the photos without adding another preferred column.
        let preferredColumns = GridGeometry.metrics(width: width).columns
        let maximumSide = max(1, availableGridHeight)
        let columns = max(preferredColumns, Int(ceil((max(1, width) + 3) / (maximumSide + 3))))
        return GridMetrics(columns: columns, tileWidth: max(1, (width - CGFloat(columns - 1) * 3) / CGFloat(columns)),
            spacing: 3, insets: .zero)
    }
}
