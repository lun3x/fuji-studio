import SwiftUI

/// One persistent grid. Only the header recognizes the drawer drag; grid scroll/sweep stays native.
struct PhotoDrawer<Header: View, Grid: View>: View {
    @Binding var detent: DrawerDetent
    let detents: DrawerDetents
    var onHeaderHeightChanged: (CGFloat) -> Void
    var onManualCollapse: () -> Void
    @ViewBuilder var header: () -> Header
    @ViewBuilder var grid: () -> Grid
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @GestureState private var isDragging = false
    @State private var drag: DrawerDrag?

    private struct DrawerDrag {
        let startHeight: CGFloat
        var height: CGFloat
    }
    private var height: CGFloat { detents.clampedHeight(drag?.height ?? detents.height(for: detent)) }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Button { move(to: detent == .collapsed ? .expanded : .collapsed) } label: {
                    Capsule().fill(.secondary).frame(width: 32, height: 5)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Photo tray")
                .accessibilityIdentifier("drawer.toggle")
                .accessibilityValue(detent == .collapsed ? "Collapsed" : "Expanded")
                .accessibilityHint("Tap or drag to expand or collapse photos")
                .accessibilityAction(named: Text("Expand photos")) { move(to: .expanded) }
                .accessibilityAction(named: Text("Collapse photos")) { move(to: .collapsed) }
                .accessibilityAdjustableAction { direction in
                    switch direction { case .increment: move(to: .expanded); case .decrement: move(to: .collapsed); @unknown default: break }
                }
                header().padding(.horizontal, 12).padding(.bottom, 8)
            }
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: onHeaderHeightChanged)
            .highPriorityGesture(DragGesture(minimumDistance: 8, coordinateSpace: .named("workspace"))
                .updating($isDragging) { _, state, _ in state = true }
                .onChanged { value in
                    let origin = drag?.startHeight ?? detents.height(for: detent)
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        drag = DrawerDrag(startHeight: origin, height: detents.clampedHeight(origin - value.translation.height))
                    }
                }
                .onEnded { value in
                    let origin = drag?.startHeight ?? detents.height(for: detent)
                    move(to: detents.destination(height: origin, predictedTranslation: value.predictedEndTranslation.height),
                         velocity: -value.velocity.height)
                })
            grid().frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(uiColor: .systemBackground))
        }
        .frame(height: height)
        .background {
            if reduceTransparency { Rectangle().fill(Color(uiColor: .systemBackground)) }
            else { Rectangle().fill(.regularMaterial) }
        }
        .clipShape(.rect(topLeadingRadius: 20, topTrailingRadius: 20))
        .onChange(of: isDragging) { _, active in
            // Gesture cancellation has no onEnded. Its reset must not reset the visible height.
            if !active, drag != nil { move(to: detent, notifyCollapse: false) }
        }
    }
    private func move(to next: DrawerDetent, velocity: CGFloat = 0, notifyCollapse: Bool = true) {
        let distance = detents.height(for: next) - height
        let initialVelocity = abs(distance) > 1 ? max(0, min(8, velocity / distance)) : 0
        // Clear the explicit drag height and commit the detent together. GestureState no longer
        // contributes to height, so its automatic reset cannot produce a second position change.
        withAnimation(reduceMotion ? nil : .interpolatingSpring(duration: 0.32, bounce: 0, initialVelocity: initialVelocity)) {
            drag = nil
            detent = next
        }
        if next == .collapsed, notifyCollapse { onManualCollapse() }
    }
}

