import SwiftUI
import UIKit

/// The tray and floating controls use the device's portrait coordinates even when
/// the window rotates. Their contents use the window's upright coordinates.
enum WorkspaceOrientation: Sendable, Equatable {
    case portrait, landscapeLeft, landscapeRight

    init(_ orientation: UIInterfaceOrientation) {
        switch orientation {
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        default: self = .portrait
        }
    }

    var contentRotation: CGFloat {
        switch self {
        case .portrait: 0
        case .landscapeLeft: -.pi / 2
        case .landscapeRight: .pi / 2
        }
    }
    var canvasAngle: Angle { .radians(-Double(contentRotation)) }
    var contentAngle: Angle { .radians(Double(contentRotation)) }

    func layoutSize(_ size: CGSize) -> CGSize {
        self == .portrait ? size : CGSize(width: size.height, height: size.width)
    }

    func layoutInsets(_ insets: EdgeInsets) -> EdgeInsets {
        switch self {
        case .portrait: insets
        case .landscapeLeft:
            EdgeInsets(top: insets.trailing, leading: insets.top, bottom: insets.leading, trailing: insets.bottom)
        case .landscapeRight:
            EdgeInsets(top: insets.leading, leading: insets.bottom, bottom: insets.trailing, trailing: insets.top)
        }
    }

    func windowFrame(_ frame: CGRect, in canvas: CGSize) -> CGRect {
        switch self {
        case .portrait: frame
        case .landscapeLeft:
            CGRect(x: canvas.height - frame.maxY, y: frame.minX, width: frame.height, height: frame.width)
        case .landscapeRight:
            CGRect(x: frame.minY, y: canvas.width - frame.maxX, width: frame.height, height: frame.width)
        }
    }

    var trayControlAlignment: Alignment {
        switch self {
        case .portrait: .top
        case .landscapeLeft: .trailing
        case .landscapeRight: .leading
        }
    }

    var popoverEdge: Edge {
        switch self {
        case .portrait: .top
        case .landscapeLeft: .trailing
        case .landscapeRight: .leading
        }
    }
}

/// Lay out upright controls at their physical portrait positions. Native glass
/// buttons and popovers remain in window coordinates, outside the rotated tray.
struct DeviceAnchoredRow: Layout {
    let orientation: WorkspaceOrientation
    var spacing: CGFloat
    var leadingItems = 1
    var reversesAxis = false

    private func sizes(_ subviews: Subviews) -> [CGSize] {
        subviews.map { orientation.layoutSize($0.sizeThatFits(.unspecified)) }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = sizes(subviews)
        let preferred = sizes.reduce(0) { $0 + $1.width } + CGFloat(max(0, sizes.count - 1)) * spacing
        let width = (orientation == .portrait ? proposal.width : proposal.height) ?? preferred
        return orientation.layoutSize(CGSize(width: width, height: sizes.map(\.height).max() ?? 0))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let canvas = orientation.layoutSize(bounds.size)
        let sizes = sizes(subviews)
        var leading: CGFloat = 0
        var trailing = canvas.width - sizes.dropFirst(leadingItems).reduce(0) { $0 + $1.width }
            - CGFloat(max(0, sizes.count - leadingItems - 1)) * spacing
        for (index, subview) in subviews.enumerated() {
            let size = sizes[index]
            let position = index < leadingItems ? leading : trailing
            let x = reversesAxis ? canvas.width - position - size.width : position
            let frame = orientation.windowFrame(CGRect(x: x, y: 0, width: size.width, height: size.height), in: canvas)
            subview.place(at: CGPoint(x: bounds.minX + frame.midX, y: bounds.minY + frame.midY),
                anchor: .center, proposal: ProposedViewSize(orientation.layoutSize(size)))
            if index < leadingItems { leading += size.width + spacing }
            else { trailing += size.width + spacing }
        }
    }
}

private struct WorkspaceOrientationKey: EnvironmentKey {
    static let defaultValue = WorkspaceOrientation.portrait
}
extension EnvironmentValues {
    var workspaceOrientation: WorkspaceOrientation {
        get { self[WorkspaceOrientationKey.self] }
        set { self[WorkspaceOrientationKey.self] = newValue }
    }
}

/// Read the owning window rather than the accelerometer: rotation lock and
/// another scene's orientation must not turn the workspace's contents sideways.
struct WorkspaceOrientationReader: UIViewControllerRepresentable {
    var onChange: (WorkspaceOrientation) -> Void

    func makeUIViewController(context: Context) -> WorkspaceOrientationController {
        WorkspaceOrientationController(onChange: onChange)
    }
    func updateUIViewController(_ controller: WorkspaceOrientationController, context: Context) {
        controller.onChange = onChange
    }
}

final class WorkspaceOrientationController: UIViewController {
    var onChange: (WorkspaceOrientation) -> Void
    private var reported: WorkspaceOrientation?

    init(onChange: @escaping (WorkspaceOrientation) -> Void) {
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        reportOrientation()
    }
    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { _ in self.reportOrientation() }, completion: { _ in self.reportOrientation() })
    }
    private func reportOrientation() {
        guard let value = view.window?.windowScene?.effectiveGeometry.interfaceOrientation, value != .unknown else { return }
        let orientation = WorkspaceOrientation(value)
        guard reported != orientation else { return }
        reported = orientation
        // UIKit can lay out this probe during a SwiftUI update.
        Task { @MainActor in self.onChange(orientation) }
    }
}
