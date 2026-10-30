import SwiftUI

/// The count/clear pair and Select share one measured span, in either tray orientation.
struct TraySelectionControlLayout: Layout {
    let orientation: WorkspaceOrientation
    var spacing: CGFloat = 12

    private func sizes(_ subviews: Subviews) -> [CGSize] {
        subviews.map { orientation.layoutSize($0.sizeThatFits(.unspecified)) }
    }
    private func canvasSize(_ sizes: [CGSize]) -> CGSize {
        CGSize(width: max(sizes[2].width, sizes[0].width + spacing + sizes[1].width),
               height: sizes.map(\.height).max() ?? 44)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        orientation.layoutSize(canvasSize(sizes(subviews)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(subviews), canvas = canvasSize(sizes)
        let countWidth = canvas.width - spacing - sizes[1].width
        let countX = orientation == .landscapeLeft ? sizes[1].width + spacing : 0
        let clearX = orientation == .landscapeLeft ? 0 : countWidth + spacing
        let clearY = orientation == .portrait ? (canvas.height - sizes[1].height) / 2 : 0
        let frames = [CGRect(x: countX, y: 0, width: countWidth, height: canvas.height),
                      CGRect(x: clearX, y: clearY, width: sizes[1].width, height: sizes[1].height),
                      CGRect(origin: .zero, size: canvas)]
        for (index, subview) in subviews.enumerated() {
            let frame = orientation.windowFrame(frames[index], in: canvas)
            subview.place(at: CGPoint(x: bounds.minX + frame.midX, y: bounds.minY + frame.midY),
                anchor: .center, proposal: ProposedViewSize(frame.size))
        }
    }
}
