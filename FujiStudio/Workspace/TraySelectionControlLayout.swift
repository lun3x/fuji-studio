import SwiftUI

/// Keep the count/clear pair horizontal in window coordinates, with Select sharing its span.
struct TraySelectionControlLayout: Layout {
    var spacing: CGFloat = 12

    private func sizes(_ subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }
    private func controlSize(_ sizes: [CGSize]) -> CGSize {
        CGSize(width: max(sizes[2].width, sizes[0].width + spacing + sizes[1].width),
               height: sizes.map(\.height).max() ?? 44)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        controlSize(sizes(subviews))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(subviews), size = controlSize(sizes)
        let countWidth = size.width - spacing - sizes[1].width
        let clearY = (size.height - sizes[1].height) / 2
        let frames = [CGRect(x: 0, y: 0, width: countWidth, height: size.height),
                      CGRect(x: countWidth + spacing, y: clearY, width: sizes[1].width, height: sizes[1].height),
                      CGRect(origin: .zero, size: size)]
        for (index, subview) in subviews.enumerated() {
            let frame = frames[index]
            subview.place(at: CGPoint(x: bounds.minX + frame.midX, y: bounds.minY + frame.midY),
                anchor: .center, proposal: ProposedViewSize(frame.size))
        }
    }
}
