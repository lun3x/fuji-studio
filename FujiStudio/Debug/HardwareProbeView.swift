#if DEBUG
import SwiftUI
import Photos
import PhotosUI
import UIKit

/// Manual Gate 1 instrumentation only. Nothing is downloaded until Inspect is tapped.
struct HardwareProbeView: View {
    @State private var model = HardwareProbeModel()
    @State private var assetID = ""

    var body: some View {
        List {
            Section("Gate 1 · Original resources") {
                Text("Device: \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)")
                Text("Access: \(model.access.rawValue)")
                Button("Request Photos read/write access") { model.discover() }
                    .disabled(model.busy)
                if model.access == .limited {
                    LimitedAccessButton().frame(height: 44)
                }
                Text("Discovery reads descriptors only. Choose one asset, then inspect its original bytes. No camera authorization is requested here.")
                    .font(.footnote)
            }
            Section("Inspect a known Photos ID (including JPEG exports)") {
                TextField("Photos local identifier", text: $assetID).textInputAutocapitalization(.never)
                Button("List resource descriptors") { model.describe(assetID) }
                    .disabled(model.busy || assetID.isEmpty)
            }
            Section("Selected resource descriptors") {
                ForEach(model.resources, id: \.discriminator) { resource in
                    VStack(alignment: .leading) {
                        Text(resource.originalFilename)
                        Text("\(resource.role.rawValue) · \(resource.contentTypeIdentifier)")
                        Text("Descriptor: \(resource.discriminator)")
                        Text("Size: \(resource.byteCount.map(String.init) ?? "unknown") bytes")
                    }.font(.caption)
                }
                Button("Retrieve and inspect selected originals") { model.inspect() }
                    .disabled(model.busy || model.resources.isEmpty)
                if model.busy {
                    ProgressView(value: model.progress)
                    Button("Cancel retrieval", role: .destructive) { model.cancel() }
                }
            }
            Section("Observed results · local session only") {
                Text(model.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Section("Eligible sources · \(model.sources.count)") {
                ForEach(model.sources) { source in
                    Button(source.originalResources.raf.originalFilename) { model.describe(source.id) }
                        .disabled(model.busy)
                }
            }
        }
        .navigationTitle("Hardware probe")
        .onDisappear { model.cancel() }
    }
}

@MainActor @Observable
private final class HardwareProbeModel {
    var access: LibraryAccess = .notDetermined
    var sources: [PhotoSource] = []
    var resources: [ResourceToken] = []
    var busy = false
    var progress = 0.0
    var output = "Gate 1 pending. Record camera firmware separately.\n"
    private let reader = PhotoLibraryReader()
    private var task: Task<Void, Never>?

    func discover() {
        task = Task {
            busy = true
            defer { busy = false }
            access = await reader.requestAccess()
            sources = []
            do {
                for try await batch in await reader.sources() { sources.append(contentsOf: batch) }
                output += "Discovery complete: \(sources.count) original RAF sources; access \(access.rawValue).\n"
            } catch { output += "Discovery failed: \(error)\n" }
        }
    }

    func describe(_ id: String) {
        task = Task {
            busy = true
            defer { busy = false }
            resources = []
            do {
                resources = try await reader.resources(assetID: id)
                output += "Listed \(resources.count) descriptors; no bytes fetched.\n"
            } catch { output += "Descriptor failure: \(error)\n" }
        }
    }

    func inspect() {
        let originals = resources.filter { $0.role != .adjusted && ($0.format == .raf || $0.format == .jpeg) }
        task = Task {
            busy = true
            defer { busy = false }
            for token in originals {
                do {
                    try Task.checkCancellation()
                    progress = 0
                    let local = try await reader.materialize(token) { value in
                        Task { @MainActor in self.progress = value }
                    }
                    defer { try? FileManager.default.removeItem(at: local.fileURL) }
                    let size = (try? local.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    output += "Retrieved \(token.format.rawValue): \(size) bytes; SHA256 \(local.checksum)\n"
                    if token.format == .raf {
                        let preparation = Task.detached { try RAFMetadataReader().prepare(local) }
                        let prepared = try await withTaskCancellationHandler {
                            try await preparation.value
                        } onCancel: { preparation.cancel() }
                        output += "Verified: \(prepared.metadata)\n"
                    }
                } catch is CancellationError {
                    output += "Cancelled; partial file removed.\n"
                    return
                } catch {
                    output += "Retrieval/metadata failure: \(error)\n"
                    return
                }
            }
        }
    }

    func cancel() { task?.cancel() }
}

private struct LimitedAccessButton: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> LimitedAccessController { LimitedAccessController() }
    func updateUIViewController(_ controller: LimitedAccessController, context: Context) {}
}

private final class LimitedAccessController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let button = UIButton(type: .system)
        button.setTitle("Manage limited Photos access", for: .normal)
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self)
        }, for: .touchUpInside)
        view = button
    }
}
#endif
