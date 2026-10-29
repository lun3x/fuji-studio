import SwiftUI

/// Native menu, kept in window coordinates alongside the other upright tray controls.
struct PhotoFilterMenu: View {
    let selected: PhotoTrayFilter
    let cameraModel: String?
    var onSelect: (PhotoTrayFilter) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    private var active: Bool { selected == .compatibleWithCamera }
    private var cameraLabel: String { cameraModel.map { "Compatible with \($0)" } ?? "Compatible with Connected Camera" }

    var body: some View {
        Menu {
            Button { onSelect(.allPhotos) } label: {
                if !active { Label("All Photos", systemImage: "checkmark") } else { Text("All Photos") }
            }.accessibilityIdentifier("filter.all")
            Button { onSelect(.compatibleWithCamera) } label: {
                if active { Label(cameraLabel, systemImage: "checkmark") } else { Text(cameraLabel) }
            }.disabled(cameraModel == nil).accessibilityIdentifier("filter.compatible")
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.headline)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background {
            if reduceTransparency { Circle().fill(Color(uiColor: .secondarySystemBackground)) }
        }
        .glassEffect(reduceTransparency ? .identity : .regular.interactive(), in: .circle)
        .overlay { if contrast == .increased { Circle().stroke(.primary, lineWidth: 1).allowsHitTesting(false) } }
        .accessibilityLabel("Filter photos")
        .accessibilityValue(active ? cameraLabel : "All Photos")
        .accessibilityHint("Choose all photos or photos compatible with the connected camera")
        .accessibilityIdentifier("workspace.filter")
    }
}
