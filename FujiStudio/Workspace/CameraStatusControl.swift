import FujiCameraCore
import SwiftUI

enum CameraIndicatorState: String {
    case disconnected = "Camera disconnected"
    case preparing = "Preparing camera"
    case ready = "Camera ready"
    case error = "Camera error"

    init(camera: CameraState, refreshingRecipes: Bool, hasError: Bool = false) {
        if hasError { self = .error; return }
        if case .attentionRequired = camera { self = .error; return }
        if refreshingRecipes {
            switch camera {
            case .opening,.discovering,.sessionOpen,.ready,.busy:self = .preparing;return
            default:break
            }
        }
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
    var exportProgress: ExportSummary? = nil
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
                .overlay(alignment: .bottom) {
                    if let exportProgress {
                        ProgressView(value: exportProgress.fractionCompleted)
                            .progressViewStyle(.linear).tint(.accentColor)
                            .frame(width: 28).padding(.bottom, 6)
                            .accessibilityHidden(true).allowsHitTesting(false)
                    }
                }
        }
        .buttonStyle(.glass).foregroundStyle(state == .error ? Color.red : Color.primary)
        .background {
            if reduceTransparency { Capsule().fill(Color(uiColor: .secondarySystemBackground)) }
        }
        .overlay { if contrast == .increased { Capsule().stroke(.primary, lineWidth: 1).allowsHitTesting(false) } }
        .accessibilityLabel(label).accessibilityValue(accessibilityValue)
        .accessibilityHint("Show app details").accessibilityIdentifier("app.status")
    }

    private var accessibilityValue: String {
        guard let exportProgress else { return state.rawValue }
        return "\(state.rawValue), Exporting, \(exportProgress.processed) of \(exportProgress.total) processed"
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
