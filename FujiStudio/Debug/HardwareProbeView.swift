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
                    Button("Refresh lifecycle snapshot") { cameraProbe.refreshLifecycle() }
                    Text(cameraProbe.diagnosticFileStatus).font(.caption2)
                    ScrollView {
                        Text(cameraProbe.trace + "\nBounded public lifecycle (no device identities):\n" + cameraProbe.lifecycleDiagnostics + "\nBounded GetDeviceInfo headers (payload omitted):\n" + cameraProbe.ptpDiagnostics)
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
    var lifecycleDiagnostics = "No lifecycle snapshot captured."
    var diagnosticFileStatus = "Refresh saves bounded diagnostics to Documents/camera-diagnostics.txt"
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
                    refreshLifecycle()
                }
            }
        }
        connecting = true
        trace += "iOS \(UIDevice.current.systemVersion); user-observed firmware: \(firmware.isEmpty ? "not recorded" : firmware)\n"
        connection = Task {
            defer { connecting = false; refreshLifecycle() }
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
                refreshLifecycle()
            }

            do {
                let reply = try await transport.execute(PTPCommand(opcode: 0x1001, parameters: [], transactionID: transaction), data: nil)
                trace += "GetDeviceInfo: response \(String(reply.responseCode, radix: 16)), logical transaction \(reply.logicalTransactionID), observed wire transaction \(reply.wireTransactionID), correlation \(reply.correlation), payload \(reply.data.count) bytes. Firmware/model parsing and RAW mode verification are Task 3 prerequisites.\n"
            } catch { trace += "Read-only PTP outcome: \(error)\n" }
        }
    }
    func disconnect() {
        connection?.cancel(); command?.cancel()
        Task { await transport.disconnect(); refreshLifecycle() }
        observation?.cancel(); observation = nil
        sessionOpen = false; connecting = false
        status = "Session invalidated; waiting for public close completion before reconnect"
    }
    func refreshLifecycle() {
        lifecycleDiagnostics = transport.lifecycleDiagnosticMessages().joined(separator: "\n")
        // Export only the bounded, sanitized driver buffers. The general probe trace can
        // contain user-entered firmware text and is intentionally excluded from this file.
        let sanitized = "Public lifecycle:\n" + lifecycleDiagnostics + "\nGetDeviceInfo headers (payload omitted):\n" + transport.ptpDiagnosticMessages().joined(separator: "\n")
        do {
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            try sanitized.write(to: directory.appendingPathComponent("camera-diagnostics.txt"), atomically: true, encoding: .utf8)
            diagnosticFileStatus = "Snapshot saved: Documents/camera-diagnostics.txt"
        } catch {
            diagnosticFileStatus = "Snapshot file could not be saved; diagnostics remain available here."
        }
    }
}

/// Explicit engineering launch mode only; ordinary launch cannot request camera authorization.
@MainActor @Observable
final class XT5ProbeLaunchRunner {
    var status = "Read-only protocol probe has not run"
    private let transport: ImageCaptureTransport
    private let requestedDirectory: URL?
    private var didRun = false
    private var directory: URL?
    private var evidenceFilename = "xt5-protocol-evidence.json"
    private var statusFilename = "xt5-protocol-status.txt"

    init(transport: ImageCaptureTransport = ImageCaptureTransport(), directory: URL? = nil) {
        self.transport = transport; self.requestedDirectory = directory
    }
    func runIfRequested(arguments: [String]) async {
        let descriptorRequested = arguments.contains("--xt5-read-only-probe")
        let directRequested = arguments.contains("--xt5-direct-values-probe")
        guard descriptorRequested != directRequested, !arguments.contains("--camera-reconnect-probe"),
              !arguments.contains("--xt5-bank-import-probe"), !arguments.contains("--xt5-raw-baseline-probe"), !arguments.contains("--xt5-unchanged-baseline-probe"), !arguments.contains("--xt5-output-recovery-probe"), !arguments.contains("--xt5-output-quarantine-probe"), !didRun else { return }
        didRun = true
        if directRequested {
            evidenceFilename = "xt5-direct-values.json"
            statusFilename = "xt5-direct-values-status.txt"
        }
        do {
            let output = try requestedDirectory ?? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            directory = output
            // Replace previous evidence before connecting so a failed attempt cannot look successful.
            try Data("{\"state\":\"awaiting device info\"}".utf8).write(to: output.appendingPathComponent(evidenceFilename), options: .atomic)
            try writeStatus("Connecting using normal public authorization")
            try await transport.connect()
            let probe = XT5ProtocolProbe(transport: transport)
            let update: @Sendable (XT5ProtocolEvidence) async -> Void = { [weak self] partial in await self?.savePartial(partial) }
            let report: XT5ProtocolEvidence
            if directRequested {
                report = try await probe.readDirectValues(onUpdate: update)
            } else {
                report = try await probe.readEvidence(onUpdate: update)
            }
            try report.json().write(to: output.appendingPathComponent(evidenceFilename), options: .atomic)
            try writeStatus("Read-only probe complete; conversion remains unvalidated")
        } catch {
            let outcome = XT5ProtocolProbe.safeError(error)
            status = outcome
            try? writeStatus(outcome)
        }
        await transport.disconnect()
        // No reconnect/retry and no assertion that asynchronous native close has completed.
        saveLifecycle()
    }
    private func savePartial(_ report: XT5ProtocolEvidence) {
        guard let directory else { return }
        do {
            try report.json().write(to: directory.appendingPathComponent(evidenceFilename), options: .atomic)
            try writeStatus("Read-only probe in progress; \(report.properties.count) property observations")
        } catch { status = "Unable to save partial evidence" }
        saveLifecycle()
    }
    private func writeStatus(_ message: String) throws {
        status = message
        guard let directory else { return }
        let text = "\(Date().formatted(.iso8601))\niOS \(UIDevice.current.systemVersion)\n\(message)\nNo conversion or seven-bank support claimed.\n"
        try text.write(to: directory.appendingPathComponent(statusFilename), atomically: true, encoding: .utf8)
    }
    private func saveLifecycle() {
        guard let directory else { return }
        let text = "Public lifecycle:\n" + transport.lifecycleDiagnosticMessages().joined(separator: "\n")
            + "\nGetDeviceInfo headers (payload omitted):\n" + transport.ptpDiagnosticMessages().joined(separator: "\n")
        try? text.write(to: directory.appendingPathComponent("camera-diagnostics.txt"), atomically: true, encoding: .utf8)
    }
}

/// A separate explicit launch mode for same-process session recovery. No payload is exported.
@MainActor @Observable
final class CameraReconnectLaunchRunner {
    var status = "Reconnect probe has not run"
    private let transport: ImageCaptureTransport
    private let requestedDirectory: URL?
    private let gate = SerialCameraGate()
    private var directory: URL?
    private var didRun = false
    private var steps: [String] = []

    init(transport: ImageCaptureTransport = ImageCaptureTransport(), directory: URL? = nil) {
        self.transport = transport; requestedDirectory = directory
    }
    func runIfRequested(arguments: [String]) async {
        guard arguments.contains("--camera-reconnect-probe"), !arguments.contains("--xt5-read-only-probe"),
              !arguments.contains("--xt5-direct-values-probe"), !arguments.contains("--xt5-bank-import-probe"), !arguments.contains("--xt5-raw-baseline-probe"), !arguments.contains("--xt5-unchanged-baseline-probe"), !arguments.contains("--xt5-output-recovery-probe"), !arguments.contains("--xt5-output-quarantine-probe"), !didRun else { return }
        didRun = true
        do {
            let output = try requestedDirectory ?? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            directory = output
            try record("Reconnect probe starting; iOS \(UIDevice.current.systemVersion)")
            saveLifecycle() // Replace prior trace before any native request.
            try await gate.withExclusiveAccess { try await self.runSequence() }
        } catch {
            try? record("Reconnect probe failed: \(XT5ProtocolProbe.safeError(error))")
            await transport.disconnect()
            saveLifecycle()
        }
    }
    private func runSequence() async throws {
        for transaction: UInt32 in [1, 2] {
            try record("Session \(transaction): connecting")
            try await transport.connect()
            let reply = try await transport.execute(PTPCommand(opcode: 0x1001, parameters: [], transactionID: transaction), data: nil)
            try record("Session \(transaction): GetDeviceInfo accepted logical=\(reply.logicalTransactionID) wire=\(reply.wireTransactionID) bytes=\(reply.data.count)")
            saveLifecycle()
            try record("Session \(transaction): awaiting native close confirmation")
            try await transport.disconnectAndWaitForConfirmation()
            try record("Session \(transaction): session closure confirmed")
            saveLifecycle()
        }
        try record("Reconnect probe complete; both session closures confirmed")
    }
    private func record(_ message: String) throws {
        status = message
        steps.append("\(Date().formatted(.iso8601)) \(message)")
        if steps.count > 16 { steps.removeFirst(steps.count - 16) }
        guard let directory else { return }
        try steps.joined(separator: "\n").write(to: directory.appendingPathComponent("camera-reconnect-status.txt"), atomically: true, encoding: .utf8)
    }
    private func saveLifecycle() {
        guard let directory else { return }
        let text = "Public lifecycle:\n" + transport.lifecycleDiagnosticMessages().joined(separator: "\n")
            + "\nGetDeviceInfo headers (payload omitted):\n" + transport.ptpDiagnosticMessages().joined(separator: "\n")
        try? text.write(to: directory.appendingPathComponent("camera-diagnostics.txt"), atomically: true, encoding: .utf8)
    }
}

/// Explicit diagnostic import. This runner exclusively owns its transport/lifecycle: connect once,
/// await the entire import and restoration, then disconnect. No independently reconnecting path.
@MainActor @Observable
final class XT5BankImportLaunchRunner {
    var status = "Bank import probe has not run"
    private let transport: ImageCaptureTransport
    private let requestedDirectory: URL?
    private var directory: URL?
    private var didRun = false
    private var artifactWriteFailed = false

    private struct PrivateCapture: Encodable {
        let complete: Bool
        let snapshots: [RecipeSnapshot]
        let verificationSnapshots: [RecipeSnapshot]
    }
    init(transport: ImageCaptureTransport = ImageCaptureTransport(), directory: URL? = nil) {
        self.transport = transport; requestedDirectory = directory
    }
    func runIfRequested(arguments: [String]) async {
        let otherFlags = ["--xt5-read-only-probe", "--xt5-direct-values-probe", "--camera-reconnect-probe", "--xt5-raw-baseline-probe", "--xt5-unchanged-baseline-probe", "--xt5-output-recovery-probe", "--xt5-output-quarantine-probe"]
        guard arguments.contains("--xt5-bank-import-probe"), !otherFlags.contains(where: arguments.contains), !didRun else { return }
        didRun = true
        do {
            let output = try requestedDirectory ?? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            directory = output
            let empty = Data("{\"state\":\"awaiting camera session\"}".utf8)
            try empty.write(to: output.appendingPathComponent("xt5-bank-import-evidence.json"), options: .atomic)
            try empty.write(to: output.appendingPathComponent("xt5-bank-import-private.json"), options: [.atomic, .completeFileProtection])
            try writeStatus("Connecting for selector-only seven-bank import")
            try await transport.connect()
            let native = transport
            let generation = try native.currentSession().generation
            let importer = XT5BankImporter(transport: native, sessionGeneration: generation, validateSession: {
                let current = try await native.currentSession()
                guard current.generation == generation else { throw XT5BankImportIssue.sessionChanged }
            })
            _ = try await importer.importRecipesVerified { [weak self] update in await self?.capture(update) }
            if artifactWriteFailed {
                try writeStatus("Import and restoration finished, but evidence file writing failed")
            } else {
                try writeStatus("Seven banks read twice; contents matched; original selector restored and verified. Rendering remains unavailable.")
            }
        } catch let failure as XT5BankImportFailure {
            let primary = failure.evidence.failure ?? "import not completed"
            let restore = failure.evidence.restorationFailure.map { "; \($0)" } ?? ""
            try? writeStatus("Bank import failed: \(primary). Selector restoration: \(failure.evidence.restoration.rawValue)\(restore)")
        } catch {
            status = "Bank probe failed: \(XT5BankImporter.safeFailure(error))"
            try? writeStatus(status)
        }
        await transport.disconnect()
        saveLifecycle()
    }
    private func capture(_ update: XT5BankImportUpdate) {
        guard let directory else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(update.evidence).write(to: directory.appendingPathComponent("xt5-bank-import-evidence.json"), options: .atomic)
            try encoder.encode(PrivateCapture(complete: update.evidence.complete, snapshots: update.snapshots, verificationSnapshots: update.verificationSnapshots))
                .write(to: directory.appendingPathComponent("xt5-bank-import-private.json"), options: [.atomic, .completeFileProtection])
            try writeStatus("Import in progress: first scan \(update.evidence.beforeSlots.count)/7, repeat scan \(update.evidence.afterSlots.count)/7; restoration \(update.evidence.restoration.rawValue)")
        } catch { artifactWriteFailed = true; status = "Evidence file writing failed; restoration must still finish" }
        saveLifecycle()
    }
    private func writeStatus(_ message: String) throws {
        status = message
        guard let directory else { return }
        let text = "\(Date().formatted(.iso8601))\niOS \(UIDevice.current.systemVersion)\n\(message)\nPrivate names/settings exist only in xt5-bank-import-private.json; do not commit that file.\n"
        try text.write(to: directory.appendingPathComponent("xt5-bank-import-status.txt"), atomically: true, encoding: .utf8)
    }
    private func saveLifecycle() {
        guard let directory else { return }
        let text = "Public lifecycle:\n" + transport.lifecycleDiagnosticMessages().joined(separator: "\n")
            + "\nGetDeviceInfo headers (payload omitted):\n" + transport.ptpDiagnosticMessages().joined(separator: "\n")
        try? text.write(to: directory.appendingPathComponent("camera-diagnostics.txt"), atomically: true, encoding: .utf8)
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
