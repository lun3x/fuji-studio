#if DEBUG
import SwiftUI
import Photos
import PhotosUI
import UIKit

/// Manual Gate 1 instrumentation only. Nothing is downloaded until Inspect is tapped.
struct HardwareProbeView: View {
    @State private var model = HardwareProbeModel()
    @State private var assetID = ""
    @State private var showingResults = false
    @State private var showingCameraResults = false
    @State private var cameraProbe = CameraProbeModel()

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
            Section("Gate 2 · USB PTP session prerequisite") {
                Text("Set USB RAW CONV./BACKUP RESTORE on the X-T5 before connecting. Record the camera firmware from its screen.")
                    .font(.footnote)
                TextField("Observed camera firmware", text: $cameraProbe.firmware)
                    .textInputAutocapitalization(.never)
                Text(cameraProbe.status).font(.caption)
                Button("Discover and open public USB PTP session") { cameraProbe.connect() }
                    .disabled(cameraProbe.connecting || cameraProbe.sessionOpen)
                Button("Read standard PTP device info (no setting writes)") { cameraProbe.readDeviceInfo() }
                    .disabled(!cameraProbe.sessionOpen || cameraProbe.commandBusy)
                Button("Close camera session") { cameraProbe.disconnect() }
                Text("Session open is not conversion ready. If no camera is visible, check cable, power and USB mode; the public API cannot distinguish those causes.")
                    .font(.footnote)
                Text(cameraProbe.trace).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Section("Eligible sources · \(model.sources.count)") {
                ForEach(model.sources) { source in
                    Button(source.originalResources.raf.originalFilename) { model.describe(source.id) }
                        .disabled(model.busy)
                }
            }
        }
        .navigationTitle("Hardware probe")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Inspect") { model.inspect() }
                    .disabled(model.busy || model.resources.isEmpty)
                Button("Results") { showingResults = true }
                Button("Camera") { showingCameraResults = true }
            }
        }
        .sheet(isPresented: $showingResults) {
            NavigationStack {
                ScrollView {
                    Text(model.output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Probe results")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingResults = false } } }
            }
        }
        .sheet(isPresented: $showingCameraResults) {
            NavigationStack {
                VStack(alignment: .leading) {
                    Text(cameraProbe.status).font(.caption)
                    HStack {
                        Button("Connect") { cameraProbe.connect() }
                            .disabled(cameraProbe.connecting || cameraProbe.sessionOpen)
                        Button("Read info") { cameraProbe.readDeviceInfo() }
                            .disabled(!cameraProbe.sessionOpen || cameraProbe.commandBusy)
                        Button("Close") { cameraProbe.disconnect() }
                    }
                    ScrollView {
                        Text(cameraProbe.trace + "\nBounded GetDeviceInfo headers (payload omitted):\n" + cameraProbe.ptpDiagnostics)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                .navigationTitle("Camera diagnostics")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingCameraResults = false } } }
            }
        }
        .onDisappear { model.cancel(); cameraProbe.disconnect() }


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

@MainActor @Observable
private final class CameraProbeModel {
    var firmware = ""
    var status = "Disconnected · physical Gate 2 pending"
    var trace = "No physical camera trace recorded.\n"
    var ptpDiagnostics = "No GetDeviceInfo callback captured."
    var connecting = false
    var sessionOpen = false
    var commandBusy = false
    private let transport = ImageCaptureTransport()
    private var observation: Task<Void, Never>?
    private var connection: Task<Void, Never>?
    private var command: Task<Void, Never>?
    private var nextTransaction: UInt32 = 1

    func connect() {
        if observation == nil {
            observation = Task {
                for await state in await transport.states() {
                    sessionOpen = false
                    switch state {
                    case .disconnected: status = "Disconnected / no visible session"
                    case .discovering: status = "Discovering (absence does not prove unplugged)"
                    case .authorizationRequired: status = "ImageCaptureCore content/control authorization required"
                    case .authorizationDenied: status = "ImageCaptureCore content/control authorization denied or restricted"
                    case .opening: status = "Opening public PTP session"
                    case .sessionOpen(let session):
                        sessionOpen = true
                        status = "Session open; conversion mode unverified · generation \(session.generation) · USB \(session.connection.usbVendorID):\(session.connection.usbProductID)"
                    case .ready: status = "Higher service verified ready (not produced by this probe)"
                    case .busy: status = "PTP command in flight"
                    case .wrongMode(let reason): status = reason
                    case .recoverableError(let error): status = "Session failed: \(error). Close/reconnect; if close is uncertain, unplug camera."
                    }
                    trace += "\(Date().formatted(.iso8601)) · \(status)\n"
                }
            }
        }
        connecting = true
        trace += "iOS \(UIDevice.current.systemVersion); user-observed firmware: \(firmware.isEmpty ? "not recorded" : firmware)\n"
        connection = Task {
            defer { connecting = false }
            do { try await transport.connect() }
            catch { trace += "Connect outcome: \(error)\n" }
        }
    }
    func readDeviceInfo() {
        guard !commandBusy else { return }
        let transaction = nextTransaction; nextTransaction += 1
        commandBusy = true
        command = Task {
            defer {
                commandBusy = false
                ptpDiagnostics = transport.ptpDiagnosticMessages().joined(separator: "\n")
            }

            do {
                let reply = try await transport.execute(PTPCommand(opcode: 0x1001, parameters: [], transactionID: transaction), data: nil)
                trace += "GetDeviceInfo: response \(String(reply.responseCode, radix: 16)), logical transaction \(reply.logicalTransactionID), observed wire transaction \(reply.wireTransactionID), correlation \(reply.correlation), payload \(reply.data.count) bytes. Firmware/model parsing and RAW mode verification are Task 3 prerequisites.\n"
            } catch { trace += "Read-only PTP outcome: \(error)\n" }
        }
    }
    func disconnect() {
        connection?.cancel(); command?.cancel()
        Task { await transport.disconnect() }
        observation?.cancel(); observation = nil
        sessionOpen = false; connecting = false
        status = "Session invalidated; waiting for public close completion before reconnect"
    }
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
