import SwiftUI

/// One persistent grid. Only the header recognizes the drawer drag; grid scroll/sweep stays native.
struct PhotoDrawer<Header: View, Grid: View>: View {
    @Binding var detent: DrawerDetent
    let detents: DrawerDetents
    let bottomInset: CGFloat
    var onHeaderHeightChanged: (CGFloat) -> Void
    var onResizeProgress: (CGFloat) -> Void = { _ in }
    var onManualCollapse: () -> Void
    @ViewBuilder var header: () -> Header
    @ViewBuilder var grid: () -> Grid
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @GestureState private var translation: CGFloat = 0

    private var height: CGFloat { detents.clampedHeight(detents.height(for: detent) - translation) }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Button { move(to: detent == .collapsed ? .expanded : .collapsed) } label: {
                    VStack(spacing: 3) {
                        Capsule().fill(.secondary).frame(width: 32, height: 5)
                        Label(detent == .collapsed ? "Expand photos" : "Collapse photos",
                              systemImage: detent == .collapsed ? "chevron.up" : "chevron.down")
                            .font(.caption)
                    }.frame(maxWidth: .infinity).padding(.top, 8).padding(.bottom, 6)
                        // Plain buttons otherwise accept only drawn label content, leaving padding inert.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("drawer.toggle")
                .accessibilityValue(detent == .collapsed ? "Collapsed" : "Expanded")
                .accessibilityAction(named: Text("Expand photos")) { move(to: .expanded) }
                .accessibilityAction(named: Text("Collapse photos")) { move(to: .collapsed) }
                .accessibilityAdjustableAction { direction in
                    switch direction { case .increment: move(to: .expanded); case .decrement: move(to: .collapsed); @unknown default: break }
                }
                header().padding(.horizontal, 12).padding(.bottom, 8)
            }
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: onHeaderHeightChanged)
            .simultaneousGesture(DragGesture(minimumDistance: 8, coordinateSpace: .named("workspace"))
                .updating($translation) { value, state, _ in state = value.translation.height }
                .onChanged { value in
                    let span = detents.expandedHeight - detents.collapsedHeight
                    onResizeProgress(span > 0 ? (detents.clampedHeight(detents.height(for: detent) - value.translation.height) - detents.collapsedHeight) / span : 0)
                }
                .onEnded { value in
                    move(to: detents.destination(height: detents.height(for: detent), predictedTranslation: value.predictedEndTranslation.height))
                })
            grid().frame(maxWidth: .infinity, maxHeight: .infinity)
            Color.clear.frame(height: bottomInset)
        }
        .frame(height: height)
        .background {
            if reduceTransparency { Rectangle().fill(Color(uiColor: .systemBackground)) }
            else { Rectangle().fill(.regularMaterial) }
        }
        .clipShape(.rect(topLeadingRadius: 20, topTrailingRadius: 20))
    }
    private func move(to next: DrawerDetent) {
        guard next != detent else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) { detent = next }
        onResizeProgress(next == .expanded ? 1 : 0)
        if next == .collapsed { onManualCollapse() }
    }
}
