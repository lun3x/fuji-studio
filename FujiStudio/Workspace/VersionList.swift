import FujiCameraCore
import SwiftUI

/// Explicit catalog associations only. A recipe selection is never an instruction to alter an
/// existing version; selecting a row emits exactly its stored VersionID.
struct VersionList: View {
    struct Entry: Identifiable {
        let id: VersionID
        let label: String
        let accessibilityIdentifier: String
        var subtitle: String? = nil
        var recipeSlot: Int? = nil
        var isPhoneRecipe = false
        var accessibilityLabel: String {
            let title = isPhoneRecipe ? "Phone recipe \(label)" : recipeSlot.map { "C\($0) \(label)" } ?? label
            return subtitle.map { title + ", " + $0 } ?? title
        }
    }
    let source: PhotoSource
    let saved: [SavedVersion]
    var selected: VersionID? = nil
    var timeZone: TimeZone = .current
    var onVersionSelected: (VersionID) -> Void = { _ in }

    var entries: [Entry] {
        var result = [Entry(id: .raw, label: "RAW", accessibilityIdentifier: "version.raw")]
        if let jpeg = source.originalResources.jpeg, jpeg.assetID == source.id,
           jpeg.role != .adjusted, jpeg.format == .jpeg {
            result.append(Entry(id: .cameraJPEG, label: "Original camera JPEG", accessibilityIdentifier: "version.cameraJPEG"))
        }
        let own = saved.filter { $0.sourceID == source.id }.sorted {
            $0.exportedAt == $1.exportedAt ? $0.id.uuidString < $1.id.uuidString : $0.exportedAt < $1.exportedAt
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = timeZone
        format.dateFormat = "dd/MM/yy HH:mm"
        let labels = own.map { $0.recipeSnapshot.displayLabel }
        let timestamps = own.map { format.string(from: $0.exportedAt) }
        for (index, version) in own.enumerated() {
            let base = labels[index]
            // Minute precision can group distinct exports. Retain stable ordinal disambiguation.
            let peers = labels.indices.filter { labels[$0] == base && timestamps[$0] == timestamps[index] }
            let ordinal = peers.count > 1 ? " · Export \((peers.firstIndex(of: index) ?? 0) + 1)" : ""
            let availability = version.availability == .available ? "" : " · unavailable (\(version.availability.rawValue))"
            result.append(Entry(id: .saved(version.id), label: version.recipeSnapshot.name,
                accessibilityIdentifier: "version.saved.\(version.id.uuidString)",
                subtitle: timestamps[index] + ordinal + availability,
                recipeSlot: version.recipeSnapshot.isPhoneRecipe ? nil : version.recipeSnapshot.slot,
                isPhoneRecipe: version.recipeSnapshot.isPhoneRecipe))
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .trailing, spacing: 0) {
                Text("Image versions").font(.headline)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding()
                ForEach(entries) { entry in
                    Button { onVersionSelected(entry.id) } label: {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "checkmark")
                                .opacity(selected == entry.id ? 1 : 0).accessibilityHidden(true)
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(entry.label)
                                if let subtitle = entry.subtitle {
                                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }.fixedSize(horizontal: false, vertical: true)
                            if entry.isPhoneRecipe {
                                Image(systemName: "iphone")
                                    .font(.caption.monospaced().weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                    .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 4))
                                    .fixedSize()
                                    .accessibilityHidden(true)
                            } else if let slot = entry.recipeSlot {
                                RecipeSlotBadge(slot: slot)
                            }
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
                            .padding(.horizontal).padding(.vertical, 8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(entry.accessibilityLabel)
                    .accessibilityIdentifier(entry.accessibilityIdentifier)
                    .accessibilityAddTraits(selected == entry.id ? .isSelected : [])
                }
            }
            .multilineTextAlignment(.trailing)
        }
        .accessibilityIdentifier("version.options")
        .frame(idealWidth: 320, maxHeight: 520)
    }
}
