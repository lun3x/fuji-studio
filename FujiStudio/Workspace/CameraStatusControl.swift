import FujiCameraCore
import SwiftUI

enum CameraIndicatorState: String {
    case disconnected = "Camera disconnected"
    case preparing = "Preparing camera"
    case ready = "Camera ready"

    init(camera: CameraState, refreshingRecipes: Bool) {
        switch camera {
        case .ready, .busy:
            // Recipe import emits busy/ready updates within one connected session.
            // Keep showing preparation until the entire import has finished.
            self = refreshingRecipes ? .preparing : .ready
        default:
            self = .disconnected
        }
    }
}

struct CameraStatusControl: View {
    let state: CameraIndicatorState
    let label: String
    var onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .headline) private var slashWidth: CGFloat = 1.8

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "camera")
                .font(.headline)
                .overlay {
                    if state == .disconnected {
                        CameraDisconnectedSlash().stroke(style: StrokeStyle(lineWidth: slashWidth, lineCap: .round))
                    }
                }
                .symbolEffect(.rotate.wholeSymbol, options: .repeating,
                    isActive: state == .preparing && !reduceMotion)
                .frame(minWidth: 44, minHeight: 44).contentShape(Capsule())
        }
        .buttonStyle(.glass).foregroundStyle(.primary)
        .background {
            if reduceTransparency { Capsule().fill(Color(uiColor: .secondarySystemBackground)) }
        }
        .overlay { if contrast == .increased { Capsule().stroke(.primary, lineWidth: 1).allowsHitTesting(false) } }
        .accessibilityLabel(label).accessibilityValue(state.rawValue)
        .accessibilityHint("Show app details").accessibilityIdentifier("app.status")
    }
}

private struct CameraDisconnectedSlash: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX - 1, y: rect.minY - 3))
            path.addLine(to: CGPoint(x: rect.maxX + 1, y: rect.maxY + 3))
        }
    }
}
