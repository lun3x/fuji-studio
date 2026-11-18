import FujiCameraCore
import SwiftUI

/// A single floating selector. Opening or dismissing it never selects a version.
struct VersionMenu: View {
    let source: PhotoSource?
    let saved: [SavedVersion]
    let selected: VersionID?
    var onVersionSelected: (VersionID) -> Void
    @State private var presented = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.timeZone) private var timeZone
    @Environment(\.workspaceOrientation) private var orientation

    private var options: VersionList? {
        guard let source else { return nil }
        return VersionList(source: source, saved: saved, selected: selected, timeZone: timeZone,
            onVersionSelected: { presented = false; onVersionSelected($0) })
    }
    var body: some View {
        WorkspaceIconButton { presented = true } label: { Image(systemName: "square.3.layers.3d") }
        .disabled(source == nil)
        .accessibilityLabel("Image versions")
        .accessibilityValue(options?.entries.first { $0.id == selected }?.accessibilityLabel ?? (source == nil ? "Select a photo" : "Camera preview"))
        .accessibilityHint("Choose the original RAW, camera JPEG or a saved version")
        .accessibilityIdentifier("workspace.versions")
        .onChange(of: source?.id) { _, _ in presented = false }
        .onDisappear { presented = false }
        .popover(isPresented: $presented, arrowEdge: orientation.popoverEdge) {
            if let options {
                options.environment(\.dynamicTypeSize, dynamicTypeSize)
                    .background { PopoverEscapeHandler(onDismiss: { presented = false }).frame(width: 1, height: 1) }
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}
