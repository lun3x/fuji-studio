import SwiftUI

/// Explicit catalog associations only. A recipe selection is never an instruction to alter an
/// existing version; selecting a row emits exactly its stored VersionID.
struct VersionList: View {
    struct Entry: Identifiable {
        let id: VersionID
        let label: String
        let accessibilityIdentifier: String
    }
    let source: PhotoSource
    let saved: [SavedVersion]
    let preview: CameraJPEG?
    var selected: VersionID? = nil
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
        format.dateStyle = .medium; format.timeStyle = .medium
        let labels = own.map { "C\($0.recipeSnapshot.slot) \($0.recipeSnapshot.name) · Exported \(format.string(from: $0.exportedAt))" }
        for (index, version) in own.enumerated() {
            let base = labels[index]
            // Ordinals disambiguate deliberately repeated exports even with identical timestamps.
            let peers = labels.indices.filter { labels[$0] == base }
            let ordinal = peers.count > 1 ? " · Export \((peers.firstIndex(of: index) ?? 0) + 1)" : ""
            let availability = version.availability == .available ? "" : " · unavailable (\(version.availability.rawValue))"
            result.append(Entry(id: .saved(version.id), label: base + ordinal + availability,
                                accessibilityIdentifier: "version.saved.\(version.id.uuidString)"))
        }
        if let preview, preview.sourceID == source.id, preview.sourceRevision == source.resourceRevision,
           preview.key.sourceID == source.id, preview.key.sourceRevision == source.resourceRevision {
            result.append(Entry(id: .preview(preview.key), label: "Temporary preview", accessibilityIdentifier: "version.preview"))
        }
        return result
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(entries) { entry in
                    Button { onVersionSelected(entry.id) } label: {
                        Text(entry.label).font(.caption).padding(10)
                            .background(selected == entry.id ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12), in: Capsule())
                    }
                    .accessibilityIdentifier(entry.accessibilityIdentifier)
                    .accessibilityAddTraits(selected == entry.id ? .isSelected : [])
                }
            }.padding(.horizontal)
        }
    }
}
