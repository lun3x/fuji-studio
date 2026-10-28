import SwiftUI

/// A single floating selector. Opening or dismissing it never selects a version.
struct VersionMenu: View {
    let source: PhotoSource
    let saved: [SavedVersion]
    let selected: VersionID?
    var onVersionSelected: (VersionID) -> Void
    var onControlFrameChanged: (CGRect) -> Void = { _ in }
    @State private var presented = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.timeZone) private var timeZone
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.workspaceOrientation) private var orientation

    private var options: VersionList {
        VersionList(source: source, saved: saved, selected: selected, timeZone: timeZone,
            onVersionSelected: { presented = false; onVersionSelected($0) })
    }
    var body: some View {
        Button { presented = true } label: {
            Image(systemName: "square.3.layers.3d").font(.headline)
                .frame(minWidth: 44, minHeight: 44).contentShape(Capsule())
        }
        .buttonStyle(.glass).foregroundStyle(.primary)
        .background {
            if reduceTransparency { Capsule().fill(Color(uiColor: .secondarySystemBackground)) }
        }
        .overlay { if contrast == .increased { Capsule().stroke(.primary, lineWidth: 1).allowsHitTesting(false) } }
        .accessibilityLabel("Image versions")
        .accessibilityValue(options.entries.first { $0.id == selected }?.accessibilityLabel ?? "No image version")
        .accessibilityHint("Choose the original RAW, camera JPEG or a saved version")
        .accessibilityIdentifier("workspace.versions")
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("workspace")) }, action: onControlFrameChanged)
        .onChange(of: source.id) { _, _ in presented = false }
        .onDisappear { presented = false; onControlFrameChanged(.zero) }
        .popover(isPresented: $presented, arrowEdge: orientation.popoverEdge) {
            options.environment(\.dynamicTypeSize, dynamicTypeSize)
                .background { PopoverEscapeHandler(onDismiss: { presented = false }).frame(width: 1, height: 1) }
                .presentationCompactAdaptation(.popover)
        }
    }
}
