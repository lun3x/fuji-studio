import FujiCameraCore
#if DEBUG
import SwiftUI
import UIKit

/// Synthetic data/pixels only. This entry never constructs Photos, camera, export or probe services.
struct WorkspaceFixtureEntry: View {
    @State private var fixture: WorkspaceFixture?
    @State private var error: String?
    var body: some View {
        Group {
            if let fixture { WorkspaceFixtureView(fixture: fixture) }
            else if let error { Text(error) }
            else { ProgressView("Generating workspace fixture") }
        }.task {
            do { fixture = try WorkspaceFixture() } catch { self.error = error.localizedDescription }
        }
    }
}

private struct WorkspaceFixtureView: View {
    let fixture: WorkspaceFixture
    @State private var state: WorkspaceState
    @State private var refreshCount = 0
    @State private var exportCount = 0
    @State private var compact = false
    @Environment(\.dynamicTypeSize) private var nativeDynamicTypeSize
    private let flags = ProcessInfo.processInfo.arguments
    init(fixture: WorkspaceFixture) {
        self.fixture = fixture
        var state = fixture.state
        if ProcessInfo.processInfo.arguments.contains("--fixture-stale") {
            state.reduce(.recipeRefreshFailed("Refresh unavailable; cached import retained."))
        }
        _state = State(initialValue: state)
    }
    var body: some View {
        GeometryReader { proxy in
            WorkspaceView(state: state, sources: fixture.sources, thumbnails: fixture.thumbnails,
                imageURL: state.displayedVersion == .raw ? nil : fixture.file.fileURL,
                imageGeometry: fixture.geometry, displayFile: fixture.file,
                imageStatus: "Generated fixture has no RAW display; original JPEG remains available.",
                onAction: { state.reduce($0) }, onRefreshRecipes: { refreshCount += 1 }, onCopyRecipeToPhone: { id in
                    guard let recipe = state.recipes.first(where: { $0.id == id }) else { return false }
                    if !state.phoneRecipes.contains(where: { $0.id == id }) {
                        state.reduce(.phoneRecipesLoaded(state.phoneRecipes + [recipe.copiedToPhone()]))
                    }
                    return true
                }, onDeletePhoneRecipe: { id in
                    guard state.phoneRecipes.contains(where: { $0.id == id }) else { return false }
                    state.reduce(.phoneRecipeDeleted(id)); return true
                }, onEditPhoneRecipe: { draft in
                    let updated = PhoneRecipe(id: draft.original.id, snapshot: try draft.makeSnapshot())
                    state.reduce(.phoneRecipeUpdated(updated))
                }, onExport: { exportCount += 1 },
                statusControl: {
                    CameraStatusControl(state: .ready, label: "Generated status", onTap: {})
                })
                .frame(width: compact ? proxy.size.width - 32 : proxy.size.width,
                    height: compact ? max(360, proxy.size.height * 0.65) : proxy.size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .overlay(alignment: .bottomLeading) {
                    if flags.contains("--fixture-compact") {
                        Button("Resize viewport") { compact.toggle() }.buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("fixture.resize")
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    VStack(alignment: .trailing) {
                        Text("Viewed: \(state.viewedSourceID ?? "none")").font(.caption2).accessibilityIdentifier("fixture.viewed")
                        Text("Export requests: \(exportCount)").font(.caption2).accessibilityIdentifier("fixture.exportCount")
                        Text("Refresh requests: \(refreshCount)").font(.caption2)
                            .accessibilityIdentifier("fixture.refreshCount").allowsHitTesting(false)
                    }.dynamicTypeSize(.large)
                }
        }
        .background { WorkspaceNativeMetrics().frame(width: 1, height: 1) }
        .preferredColorScheme(flags.contains("--fixture-dark") ? .dark : .light)
        .environment(\.dynamicTypeSize, flags.contains("--fixture-accessibility") ? .accessibility5 : nativeDynamicTypeSize)
    }
}

@MainActor
final class WorkspaceFixture {
    let sources: [PhotoSource]
    let file: DisplayFileLease
    let geometry: ImageGeometry
    let thumbnails = WorkspaceFixtureThumbnails()
    let state: WorkspaceState
    init() throws {
        let portrait = ProcessInfo.processInfo.arguments.contains("--fixture-portrait")
        let size = portrait ? CGSize(width: 1200, height: 1800) : CGSize(width: 1800, height: 1200)
        geometry = ImageGeometry(encoded: PixelSize(width: Int(size.width), height: Int(size.height)), orientation: 1)
        sources = (0..<120).map { index in
            let id = "source-\(index)"
            return PhotoSource(id: id, originalResources: .init(raf: .init(assetID: id, role: .primaryOriginal,
                contentTypeIdentifier: "com.fujifilm.raw-image", format: .raf, originalFilename: "GENERATED_\(index).RAF", discriminator: "raw"),
                jpeg: .init(assetID: id, role: .alternateOriginal, contentTypeIdentifier: "public.jpeg", format: .jpeg,
                    originalFilename: "GENERATED_\(index).JPG", discriminator: "jpeg")), captureDate: nil, location: nil, resourceRevision: "generated")
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let data = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.95) { renderer in
            let c = renderer.cgContext
            UIColor(red: 0.67, green: 0.78, blue: 0.83, alpha: 1).setFill(); c.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.93, green: 0.77, blue: 0.46, alpha: 1).setFill(); c.fillEllipse(in: CGRect(x: 1200, y: 150, width: 180, height: 180))
            for layer in 0..<5 {
                UIColor(red: 0.24 - Double(layer) * 0.025, green: 0.4 - Double(layer) * 0.035, blue: 0.38 - Double(layer) * 0.025, alpha: 1).setFill()
                let path = UIBezierPath(); path.move(to: CGPoint(x: 0, y: 500 + layer * 130))
                path.addCurve(to: CGPoint(x: 1800, y: 520 + layer * 130), controlPoint1: CGPoint(x: 450, y: 100 + layer * 140), controlPoint2: CGPoint(x: 1000, y: 900 + layer * 80))
                path.addLine(to: CGPoint(x: 1800, y: 1200)); path.addLine(to: CGPoint(x: 0, y: 1200)); path.close(); path.fill()
            }
            "GENERATED LANDSCAPE".draw(at: CGPoint(x: 80, y: 1050), withAttributes: [.font: UIFont.preferredFont(forTextStyle: .largeTitle), .foregroundColor: UIColor.white])
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-generated-\(UUID().uuidString).JPG")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url); file = try DisplayFileLease.copy(from: url)
        let context = RecipeCameraContext(model: "X-T5", firmware: "4.31", capability: "X-T5_0200", sessionIdentity: UUID(), sessionGeneration: 1)
        var properties = Dictionary(uniqueKeysWithValues: (UInt16(0xD18E)...0xD1A4).map { ($0, UInt16(1)) })
        for (k,v): (UInt16, UInt16) in [0xD18E:7,0xD18F:2,0xD190:400,0xD191:0,0xD192:11,0xD193:0,0xD194:0,0xD195:3,0xD196:3,0xD197:2,0xD198:1,0xD199:2,0xD19A:65532,0xD19B:3,0xD19C:6700,0xD19D:65516,0xD19E:20,0xD19F:0,0xD1A0:0,0xD1A1:32768,0xD1A2:0] { properties[k] = v }
        let names = ["Soft daylight", "Warm shadows", "Mountain greens", "Quiet colour", "Evening light", "Monochrome", "Unsupported import"]
        let recipes = try (1...7).map { slot in
            let name = names[slot - 1]
            var nameData = Data([UInt8(name.utf16.count + 1)])
            for word in name.utf16 { nameData.append(contentsOf: [UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8)]) }
            nameData.append(contentsOf: [0, 0])
            var values = properties
            if slot == 4, ProcessInfo.processInfo.arguments.contains("--fixture-astia-film") {
                values[0xD192] = 3 // Regression for an existing phone recipe using ASTIA.
            }
            if slot == 7 { values[0xD18E] = 65535 }
            return try XT5RecipeCodec.recipe(slot: slot, nameData: nameData,
                properties: values.mapValues { Data([UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)]) }, context: context, importedAt: Date(timeIntervalSince1970: 0))
        }
        var state = WorkspaceState(sources: sources, access: .full)
        state.reduce(.recipesLoaded(recipes,slots:RecipeCodecRegistry.xt5Capabilities.bankSlots))
        state.reduce(.cameraChanged(.ready(CameraSession(generation: 1, connection: .init(name: "Generated fixture", usbVendorID: 0, usbProductID: 0))), context: CameraExecutionContext(model: context.model, firmware: context.firmware, capability: context.capability,
            supportVersion: XT5WorkingProfile.supportVersion, sessionIdentity: context.sessionIdentity, generation: 1)))
        if let execution=state.currentCameraExecutionContext {
            let support = try fixtureCameraSupport(execution)
            state.reduce(.cameraSupportVerified(execution, support))
            if ProcessInfo.processInfo.arguments.contains("--fixture-filter-sources") {
                for (index, source) in sources.enumerated() {
                    state.reduce(.photoFilterAssessed(source, camera: PhotoTrayFilterCamera(support),
                        result: index.isMultiple(of: 3) ? .compatible : .incompatible))
                }
            }
        }
        state.reduce(.recipeSelected(slot: 3))
        state.reduce(.sourceTapped("source-0")); self.state = state
    }
}

@MainActor
final class WorkspaceFixtureThumbnails: GridThumbnailProviding {
    func request(sourceID: SourceID, pixelSize: CGSize, completion: @escaping @MainActor (UIImage?) -> Void) -> UUID {
        let index = Int(sourceID.replacingOccurrences(of: "source-", with: "")) ?? 0
        completion(UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { renderer in
            UIColor(hue: CGFloat(index % 20) / 20, saturation: 0.32, brightness: 0.5, alpha: 1).setFill()
            renderer.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            "\(index)".draw(at: CGPoint(x: 10, y: 25), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 28, weight: .semibold), .foregroundColor: UIColor.white])
        })
        return UUID()
    }
    func cancel(_ token: UUID) {}
    func cache(sourceIDs: [SourceID], pixelSize: CGSize) {}
}
#endif

#if DEBUG
/// Native validation facts; one-point, noninteractive fixture probe never participates in product layout.
private struct WorkspaceNativeMetrics: UIViewRepresentable {
    func makeUIView(context: Context) -> WorkspaceNativeMetricsView { WorkspaceNativeMetricsView() }
    func updateUIView(_ uiView: WorkspaceNativeMetricsView, context: Context) {}
}
private final class WorkspaceNativeMetricsView: UIView {
    private var link: CADisplayLink?
    private var drawerPositions: [CGFloat] = []
    override func didMoveToWindow() {
        super.didMoveToWindow(); link?.invalidate(); link = nil
        if window != nil && ProcessInfo.processInfo.arguments.contains("--fixture-drawer-trace") {
            let link = CADisplayLink(target: self, selector: #selector(recordDrawerPosition))
            link.add(to: .main, forMode: .common); self.link = link
        }
    }
    @objc private func recordDrawerPosition() {
        guard let window else { return }
        func find(_ view: UIView) -> UIView? {
            if view.accessibilityIdentifier == "photoGrid" { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let grid = find(window) else { return }
        let y = grid.convert(grid.bounds, to: window).minY
        if drawerPositions.last.map({ abs($0 - y) > 0.02 }) ?? true {
            drawerPositions.append(y)
            if drawerPositions.count > 512 { drawerPositions.removeFirst() }
        }
    }
    override var accessibilityValue: String? {
        get { drawerPositions.map { String(format: "%.3f", $0) }.joined(separator: ",") }
        set {}
    }
    init() { super.init(frame: .zero); isAccessibilityElement = true; accessibilityIdentifier = "fixture.nativeMetrics"; isUserInteractionEnabled = false }
    required init?(coder: NSCoder) { fatalError() }
    override var accessibilityLabel: String? {
        get {
            guard let window else { return "No window" }
            return "Window \(window.bounds); safe \(window.safeAreaInsets); root safe \(window.rootViewController?.view.safeAreaInsets ?? .zero); orientation \(window.windowScene?.effectiveGeometry.interfaceOrientation.rawValue ?? 0); content size \(window.traitCollection.preferredContentSizeCategory.rawValue); contrast \(window.traitCollection.accessibilityContrast.rawValue); reduce transparency \(UIAccessibility.isReduceTransparencyEnabled); reduce motion \(UIAccessibility.isReduceMotionEnabled)"
        }
        set {}
    }
}
#endif
