#if DEBUG
import SwiftUI
import UIKit

/// Generated records/pixels only. Does not construct Photos, camera, or probe services.
struct GridFixtureEntry: View {
    private let sources: [PhotoSource]
    private let thumbnails = GeneratedGridThumbnails()
    @State private var state: WorkspaceState
    @State private var compact = false
    @State private var metrics = GridGeometry.metrics(width: 1)
    @State private var scrollRequest: GridScrollRequest?
    init() {
        let sources = (0..<1000).map { index in
            let id = "source-\(index)"
            return PhotoSource(id: id, originalResources: .init(raf: .init(assetID: id, role: .primaryOriginal,
                contentTypeIdentifier: "com.fujifilm.raw-image", format: .raf, originalFilename: "GENERATED.RAF", discriminator: "raw"), jpeg: nil),
                captureDate: nil, location: nil, resourceRevision: "generated", compatibility: .unknown)
        }
        self.sources = sources; _state = State(initialValue: WorkspaceState(sources: sources, access: .full))
    }
    var body: some View {
        VStack(spacing: 8) {
            Text("Generated 1,000 photo fixture").font(.headline)
            HStack {
                Button(state.isSelecting ? "Cancel selection" : "Select") { state.reduce(state.isSelecting ? .done : .select) }
                Button("Resize") {
                    compact.toggle()
                    if let id = state.viewedSourceID {
                        scrollRequest = GridScrollRequest(sourceID: id, afterViewportHeight: compact ? metrics.height(rows: 2) : 380)
                    }
                }
            }.buttonStyle(.bordered)
            Text(verbatim: "Checked: \(state.checkedSourceIDs.count)").accessibilityIdentifier("gridFixture.checked")
            Text(verbatim: "Viewed: \(state.viewedSourceID ?? "none")").accessibilityIdentifier("gridFixture.viewed")
            PhotoGrid(sources: sources, checkedSourceIDs: state.checkedSourceIDs, isSelecting: state.isSelecting,
                viewedSourceID: state.viewedSourceID, thumbnails: thumbnails, scrollRequest: scrollRequest,
                onSourceTapped: { state.reduce(.sourceTapped($0)) }, onCheckedChanged: { state.reduce(.checkedSourcesReplaced($0)) },
                onViewportChanged: { viewport in
                    if metrics != viewport.metrics { Task { @MainActor in metrics = viewport.metrics } }
                })
                .frame(height: compact ? metrics.height(rows: 2) : 380)
            Spacer(minLength: 0)
        }.padding(.top, 8)
    }
}

@MainActor
private final class GeneratedGridThumbnails: GridThumbnailProviding {
    func request(sourceID: SourceID, pixelSize: CGSize, completion: @escaping @MainActor (UIImage?) -> Void) -> UUID {
        let index = Int(sourceID.replacingOccurrences(of: "source-", with: "")) ?? 0
        let size = CGSize(width: 128, height: 128)
        completion(UIGraphicsImageRenderer(size: size).image { context in
            UIColor(hue: CGFloat(index % 31) / 31, saturation: 0.35, brightness: 0.48, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            "\(index)".draw(at: CGPoint(x: 10, y: 25), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 28, weight: .semibold), .foregroundColor: UIColor.white])
        })
        return UUID()
    }
    func cancel(_ token: UUID) {}
    func cache(sourceIDs: [SourceID], pixelSize: CGSize) {}
}
#endif
