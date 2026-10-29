import FujiCameraCore
import SwiftUI

/// The containing row supplies the slot in its accessibility label.
struct RecipeSlotBadge: View {
    let slot: Int

    var body: some View {
        Text("C\(slot)")
            .font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
            .accessibilityHidden(true)
    }
}
