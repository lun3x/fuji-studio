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

struct WirelessStatusSummary: Equatable {
    let label: String
    let symbol: String
    let importCounts: String?

    init?(state: WirelessConnectionState, activeImport: ImportEvent? = nil, preparingImport: Bool = false) {
        if let activeImport, let status = activeImport.activeStatusLabel {
            label = status
            symbol = "square.and.arrow.down"
            importCounts = activeImport.captureCountLabel
            return
        }
        importCounts = nil
        if preparingImport {
            label = "Preparing camera originals…"
            symbol = "square.and.arrow.down"
        } else if state.wifi != .idle {
            label = state.wifi.statusLabel
            symbol = "wifi"
        } else if state.isListeningForAutoSave {
            label = "Listening for PC Auto Save"
            symbol = "wifi"
        } else if state.bluetooth != .idle {
            label = state.bluetooth.statusLabel
            symbol = "antenna.radiowaves.left.and.right"
        } else {
            return nil
        }
    }
}

struct CameraStatusControl: View {
    let state: CameraIndicatorState
    let label: String
    var exportProgress: ExportSummary? = nil
    var wireless: WirelessStatusSummary? = nil
    var bluetooth: WirelessBluetoothReadiness = .idle
    var onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .headline) private var slashWidth: CGFloat = 1.8

    var body: some View {
        Button(action: onTap) {
            Image(systemName: bluetooth == .connecting || bluetooth == .pairing || bluetooth == .ready ? "camera" : state == .disconnected ? wireless?.symbol ?? "camera" : "camera")
                .font(.headline)
                .overlay {
                    if state == .disconnected && wireless == nil {
                        CameraDisconnectedSlash().stroke(style: StrokeStyle(lineWidth: slashWidth, lineCap: .round))
                    }
                }
                .symbolEffect(.rotate.wholeSymbol, options: .repeating,
                    isActive: (state == .preparing || bluetooth == .connecting || bluetooth == .pairing) && !reduceMotion)
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
        var parts = [state.rawValue]
        if let wireless {
            parts[0] = switch state {
            case .disconnected: "USB camera disconnected"
            case .preparing: "Preparing USB camera"
            case .ready: "USB camera ready"
            case .error: "USB camera error"
            }
            parts.append(wireless.label)
            if let counts = wireless.importCounts { parts.append(counts) }
        }
        if let exportProgress {
            parts.append("Exporting, \(exportProgress.processed) of \(exportProgress.total) processed")
        }
        return parts.joined(separator: ", ")
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
