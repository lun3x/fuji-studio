#if DEBUG
import SwiftUI
import UIKit

/// Generated pixels and in-memory state only. This entry never constructs camera/Photos services.
struct ViewerFixtureEntry: View {
    @State private var fixture: ViewerFixture?
    @State private var error: String?
    var body: some View {
        Group {
            if let fixture { ViewerFixtureView(fixture: fixture) }
            else if let error { Text(error) }
            else { ProgressView("Generating detailed fixture") }
        }.task {
            do { fixture = try ViewerFixture() } catch { self.error = error.localizedDescription }
        }
    }
}

private struct ViewerFixtureView: View {
    let fixture: ViewerFixture
    @State private var state: WorkspaceState
    @State private var compactViewport = false
    @State private var loadingStep = 0
    init(fixture: ViewerFixture) {
        self.fixture = fixture
        _state = State(initialValue: fixture.state)
    }
    var body: some View {
        let source = state.viewedSourceID == fixture.source.id ? fixture.source : fixture.otherSource
        let version = state.displayedVersion ?? .cameraJPEG
        let file = version == .saved(fixture.saved.id) ? fixture.savedFile : fixture.originalFile
        VStack {
            Text("Generated detail fixture").font(.headline)
            PhotoViewer(sourceID: source.id, version: version, imageURL: version == .raw ? nil : file.fileURL,
                geometry: fixture.geometry, displayFile: file,
                loading: loadingStep == 0 ? nil : loadingStep == 2 ? .downloading(0.25) : .loading,
                status: loadingStep == 0 ? nil : loadingStep == 2 ? "Downloading image… 25%" : "Loading image…")
                .frame(height: compactViewport ? 210 : nil)
                .overlay(alignment: .topTrailing) {
                    VersionMenu(source: source, saved: [fixture.saved], selected: version,
                        onVersionSelected: { state.reduce(.versionSelected($0)) }).padding(8)
                }
            Text(version == .cameraJPEG ? "Original camera JPEG" : version == .raw ? "RAW" : "Stored version")
                .font(.caption).accessibilityIdentifier("fixture.selection")
            Text("Selected recipe: C\(state.selectedRecipe?.slot ?? 0) \(state.selectedRecipe?.name ?? "none")")
                .font(.caption).accessibilityIdentifier("fixture.recipe")
            HStack {
                Button("Resize viewport") { compactViewport.toggle() }.accessibilityIdentifier("fixture.resize")
                Button("Next source") { state.reduce(.sourceTapped(fixture.otherSource.id)); state.reduce(.versionSelected(.cameraJPEG)) }
                    .accessibilityIdentifier("fixture.nextSource")
                Button("Deliver late preview") { state.reduce(.previewCompleted(request: fixture.request, key: fixture.preview.key)) }
                    .accessibilityIdentifier("fixture.latePreview")
            }.buttonStyle(.bordered)
            if ProcessInfo.processInfo.arguments.contains("--viewer-loading-controls") {
                Button("Advance loading") { loadingStep = (loadingStep + 1) % 4 }
                    .accessibilityIdentifier("fixture.loading")
            }
        }.padding(.vertical, 8)
    }
}

private struct ViewerFixture {
    let source: PhotoSource, otherSource: PhotoSource
    let geometry = ImageGeometry(encoded: PixelSize(width: 6000, height: 4000), orientation: 1)
    let originalFile: DisplayFileLease, savedFile: DisplayFileLease
    let preview: CameraJPEG, saved: SavedVersion
    let state: WorkspaceState, request: WorkspacePreviewRequest
    @MainActor init() throws {
        originalFile = try Self.image(variant: false); savedFile = try Self.image(variant: true)
        func source(_ id: String) -> PhotoSource {
            PhotoSource(id: id, originalResources: .init(raf: .init(assetID: id, role: .primaryOriginal, contentTypeIdentifier: "com.fujifilm.raw-image", format: .raf, originalFilename: "GENERATED.RAF", discriminator: "raw", sourceRevision: "fixture"),
                jpeg: .init(assetID: id, role: .alternateOriginal, contentTypeIdentifier: "public.jpeg", format: .jpeg, originalFilename: "GENERATED.JPG", discriminator: "jpeg", sourceRevision: "fixture")), captureDate: nil, location: nil, resourceRevision: "fixture")
        }
        self.source = source("viewer-fixture-one"); otherSource = source("viewer-fixture-two")
        let context = RecipeCameraContext(model: "X-T5", firmware: "4.31", capability: "X-T5_0200", sessionIdentity: UUID(), sessionGeneration: 1)
        let camera = CameraExecutionContext(model: context.model, firmware: context.firmware, capability: context.capability,
            supportVersion: XT5WorkingProfile.supportVersion, sessionIdentity: context.sessionIdentity, generation: 1)
        var properties = Dictionary(uniqueKeysWithValues: (UInt16(0xD18E)...0xD1A4).map { ($0, UInt16(1)) })
        for (k,v): (UInt16, UInt16) in [0xD18E:7,0xD18F:2,0xD190:400,0xD191:0,0xD192:11,0xD193:0,0xD194:0,0xD195:3,0xD196:3,0xD197:2,0xD198:1,0xD199:2,0xD19A:65532,0xD19B:3,0xD19C:6700,0xD19D:65516,0xD19E:20,0xD19F:0,0xD1A0:0,0xD1A1:32768,0xD1A2:0] { properties[k] = v }
        let name = "Fixture recipe"
        var nameData = Data([UInt8(name.utf16.count + 1)])
        for word in name.utf16 { nameData.append(contentsOf: [UInt8(truncatingIfNeeded: word), UInt8(truncatingIfNeeded: word >> 8)]) }
        nameData.append(contentsOf: [0, 0])
        let recipes = try (1...7).map { try XT5RecipeCodec.recipe(slot: $0, nameData: nameData,
            properties: properties.mapValues { Data([UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)]) },
            context: context, importedAt: Date(timeIntervalSince1970: 0)) }
        let recipe = recipes[2], normalized = try recipe.normalizedSettings
        let key = RenderKey(sourceID: self.source.id, sourceRevision: "fixture", sourceSHA256: "generated", settingsDigest: recipe.settingsDigest,
            cameraContext: camera, width: 6000, height: 4000, orientation: 1, policy: .fullSizeFineRecordedGeometry, quality: .fullResolutionFine)
        preview = CameraJPEG(fileURL: savedFile.fileURL, sourceID: self.source.id, sourceRevision: "fixture", sourceSHA256: "generated", recipeSnapshotID: recipe.id,
            settingsDigest: recipe.settingsDigest, cameraContext: camera, operationID: UUID(), width: 6000, height: 4000, orientation: 1, quality: .fullResolutionFine,
            effectiveRecipe: .init(supportVersion: normalized.supportVersion, requested: normalized, dormantGrainSizeNotSerialized: false, inactiveKelvinPreserved: false,
                lensOptimizerRequested: false, lensOptimizerEffective: false, lensOptimizerAdjusted: false, evidence: "Generated viewer fixture; not a camera conversion"),
            baselineSHA256: "generated", candidateSHA256: "generated", outputSHA256: try ResourceChecksum.sha256(savedFile.fileURL), key: key)
        saved = SavedVersion(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, sourceID: self.source.id, outputAssetID: "generated-output",
            recipeSnapshot: recipe, operationID: UUID(), exportedAt: Date(timeIntervalSince1970: 1_700_000_000), jpeg: preview, availability: .available)
        var state = WorkspaceState(sources: [self.source, otherSource], access: .full)
        state.reduce(.recipesRefreshed(recipes))
        state.reduce(.cameraChanged(.ready(CameraSession(generation: 1, connection: .init(name: "Generated fixture", usbVendorID: 0, usbProductID: 0))), context: camera))
        state.reduce(.recipeSelected(slot: 3))
        let effects = state.reduce(.sourceTapped(self.source.id))
        guard case .requestPreview(let request) = effects.first else { throw ViewerError.invalidVersion }
        self.request = request
        state.reduce(.versionSelected(.cameraJPEG)); self.state = state
    }
    @MainActor private static func image(variant: Bool) throws -> DisplayFileLease {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let data = UIGraphicsImageRenderer(size: CGSize(width: 6000, height: 4000), format: format).jpegData(withCompressionQuality: 0.97) { renderer in
            let c = renderer.cgContext
            (variant ? UIColor(red: 0.16, green: 0.23, blue: 0.3, alpha: 1) : UIColor(red: 0.22, green: 0.16, blue: 0.12, alpha: 1)).setFill()
            c.fill(CGRect(x: 0, y: 0, width: 6000, height: 4000))
            for x in stride(from: 0, to: 6000, by: 100) {
                for y in stride(from: 0, to: 4000, by: 100) {
                    UIColor(white: (x + y) % 200 == 0 ? 0.8 : 0.3, alpha: 1).setStroke()
                    c.setLineWidth(2); c.stroke(CGRect(x: x + 4, y: y + 4, width: 92, height: 92))
                    "\(x / 100),\(y / 100)".draw(at: CGPoint(x: x + 12, y: y + 35), withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 18, weight: .medium), .foregroundColor: UIColor.white])
                }
            }
            UIColor.systemYellow.setStroke(); c.setLineWidth(12)
            c.strokeEllipse(in: CGRect(x: 3400, y: 1400, width: 500, height: 500))
            "6000 × 4000 • GENERATED DETAIL".draw(at: CGPoint(x: 250, y: 250), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 100), .foregroundColor: UIColor.white])
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).JPG")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        return try DisplayFileLease.copy(from: url)
    }
}
#endif
