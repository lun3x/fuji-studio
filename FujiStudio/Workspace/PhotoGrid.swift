import FujiCameraCore
import SwiftUI

struct GridScrollRequest: Equatable {
    let id: UUID
    let sourceID: SourceID
    /// Wait for this actual grid height before revealing, e.g. a manual drawer collapse.
    let afterViewportHeight: CGFloat?
    init(sourceID: SourceID, afterViewportHeight: CGFloat? = nil) {
        id = UUID(); self.sourceID = sourceID; self.afterViewportHeight = afterViewportHeight
    }
}

struct GridViewport: Equatable {
    let metrics: GridMetrics
    let size: CGSize
    let contentOffset: CGPoint
    let visibleSourceIDs: [SourceID]
    let dayHeaderHeight: CGFloat
}

enum DrawerScrollDrag: Equatable {
    case changed(translation: CGFloat)
    case ended(translation: CGFloat, velocity: CGFloat)
    case cancelled
}

/// Read-side thumbnails only. Full detail images are supplied separately to PhotoViewer.
struct PhotoGrid: UIViewControllerRepresentable {
    let sources: [PhotoSource]
    let checkedSourceIDs: Set<SourceID>
    let isSelecting: Bool
    let viewedSourceID: SourceID?
    let thumbnails: any GridThumbnailProviding
    var scrollRequest: GridScrollRequest? = nil
    var gridMetrics: GridMetrics? = nil
    var bottomInset: CGFloat = 0
    var contentRotation: CGFloat = 0
    var allowsDrawerCollapse = false
    var dayHeaderControlsSize: CGSize = .zero
    var onSourceTapped: (SourceID) -> Void
    var onCheckedChanged: (Set<SourceID>) -> Void
    var onDayTapped: (Set<SourceID>) -> Void = { _ in }
    var onViewportChanged: (GridViewport) -> Void = { _ in }
    var onDrawerDrag: (DrawerScrollDrag) -> Void = { _ in }

    func makeUIViewController(context: Context) -> PhotoGridController { PhotoGridController(thumbnails: thumbnails) }
    func updateUIViewController(_ controller: PhotoGridController, context: Context) {
        controller.onSourceTapped = onSourceTapped; controller.onCheckedChanged = onCheckedChanged
        controller.onDayTapped = onDayTapped
        controller.onViewportChanged = onViewportChanged
        controller.onDrawerDrag = onDrawerDrag
        controller.update(sources: sources, checked: checkedSourceIDs, selecting: isSelecting,
                          viewed: viewedSourceID, scrollRequest: scrollRequest, gridMetrics: gridMetrics,
                          bottomInset: bottomInset, contentRotation: contentRotation, allowsDrawerCollapse: allowsDrawerCollapse,
                          dayHeaderControlsSize: dayHeaderControlsSize)
    }
    static func dismantleUIViewController(_ controller: PhotoGridController, coordinator: ()) { controller.stop() }
}
