import FujiCameraCore
import SwiftUI

struct CameraConnectionSection: View {
    let model: AppModel
    let connection: PresentedCameraConnection
    let onBrowse: () -> Void
    let onSetUpAutoSave: () -> Void
    private enum SetupStep { case modelPicker, xt5 }
    @State private var setupStep: SetupStep?
    private var addingCamera: Bool { setupStep != nil }
    @State private var confirmingForget = false
    @State private var retryingBluetooth = false

    private var state: WirelessConnectionState { model.wirelessState }
    private var selected: SavedCamera? { state.savedCameras.first { $0.id == state.selectedCameraID } }
    private var discovering: Bool { state.bluetooth == .discovering || state.bluetooth == .pairing }
    private var connected: Bool { state.wifi == .ready && !model.isDisconnectingWireless }
    private var disconnecting: Bool { state.wifi == .disconnecting || model.isDisconnectingWireless }
    private var unconfirmedClose: Bool { state.wifi == .idle && state.hasTransferLease }
    private var canChoose: Bool { !model.state.wirelessRestrictsUSB && !discovering && !connection.isWorking && !model.cameraImportActive }
    private var canOpenTransfer: Bool { canChoose && !model.isSuspended }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selected, !addingCamera {
                Text(selected.displayName).font(.headline).accessibilityIdentifier("wireless.selected")
            }
            if !state.hasAutomaticAutoSaveDestination && !addingCamera && (selected != nil || discovering) && state.wifi == .idle {
                Label(state.bluetooth.statusLabel, systemImage: "antenna.radiowaves.left.and.right")
                    .accessibilityIdentifier("wireless.bluetooth")
            }
            if state.wifi != .idle || disconnecting || unconfirmedClose || state.isListeningForAutoSave {
                Label(wifiStatus, systemImage: "wifi").accessibilityIdentifier("wireless.wifi")
            }
            if connected {
                Button("Browse camera photos", action: onBrowse)
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("wireless.browse")
                disconnectButton
            } else if disconnecting {
                ProgressView().accessibilityLabel("Disconnecting WiFi")
            } else if unconfirmedClose {
                disconnectButton
            } else if state.wifi != .idle || discovering || connection.isWorking {
                if state.bluetooth == .discovering && state.wifi == .idle {
                    Text("Choose your camera when it appears. Keep Pairing Registration open on the camera.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(state.discoveredCameras.filter { $0.advertisedModelHint != .xe3 }) { camera in
                        Button(camera.displayName) {
                            connection.start(from: .status) { await model.pairWirelessCamera(camera) }
                        }
                            .disabled(connection.isWorking || model.cameraImportActive)
                            .accessibilityIdentifier(camera.discoveryAccessibilityID)
                    }
                }
                if state.bluetooth == .pairing {
                    Text("Confirm the pairing request on your camera and iPhone.")
                }
                Button("Cancel", action: cancel).accessibilityIdentifier("wireless.cancel")
            } else {
                connectionActions
                if retryingBluetooth && state.bluetooth == .connecting {
                    Button("Cancel", action: cancel).accessibilityIdentifier("wireless.cancel")
                }
            }
            connectionMessages
        }
        .alert("Forget camera?", isPresented: $confirmingForget, presenting: selected) { camera in
            Button("Forget camera", role: .destructive) {
                setupStep = nil
                Task { await model.forgetWirelessCamera(camera.id) }
            }
            .disabled(model.cameraImportActive)
            Button("Cancel", role: .cancel) {}
        } message: { camera in
            Text("To pair \(camera.displayName) again, remove its pairing registration on the camera and forget it in iPhone Bluetooth settings if it still appears there.")
        }
        .onChange(of: state.selectedCameraID) { setupStep = nil }
        .onChange(of: state.bluetooth) { _, readiness in
            if readiness != .connecting { retryingBluetooth = false }
        }
    }

    private var wifiStatus: String {
        if disconnecting { return WirelessWiFiPhase.disconnecting.statusLabel }
        if state.isListeningForAutoSave { return "Listening for PC Auto Save" }
        return unconfirmedClose ? "WiFi closure unconfirmed" : state.wifi.statusLabel
    }

    @ViewBuilder private var connectionActions: some View {
        if selected != nil && !addingCamera && !retryingBluetooth && !state.hasAutomaticAutoSaveDestination {
            if state.bluetooth == .ready {
                Text("Your camera is paired. Connect to its Wi-Fi to import photos.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button("Connect for photo import") {
                connection.start(from: .status) { await model.connectCameraWiFi() }
            }
                .buttonStyle(.borderedProminent)
                .disabled(!canOpenTransfer)
                .accessibilityIdentifier("wireless.connect")
        }
        if !addingCamera && (state.bluetooth == .unavailable || state.bluetooth == .waitingForCamera) {
            if selected != nil && !state.hasAutomaticAutoSaveDestination {
                Button("Retry Bluetooth") {
                    retryingBluetooth = true
                    connection.start(from: .status) { await model.retryCameraBluetooth() }
                }
                    .disabled(!canChoose).accessibilityIdentifier("wireless.retry")
            }
        }
        if selected == nil || addingCamera {
            if setupStep == .xt5 {
                Text("On your X-T5, open the connection settings and start Pairing Registration.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("wireless.pairInstructions")
                Button("Find my X-T5") {
                    setupStep = nil
                    connection.start(from: .status) { await model.discoverWirelessCameras() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canChoose).accessibilityIdentifier("wireless.pair")
                Button("Choose a different model") { setupStep = .modelPicker }
            } else {
                Text("Which camera are you setting up?").font(.headline)
                modelChoice("X-T5", route: "Bluetooth") { setupStep = .xt5 }
                    .disabled(!canChoose).accessibilityIdentifier("wireless.model.xt5")
                Divider()
                modelChoice("X-E3", route: "PC Auto Save", action: onSetUpAutoSave)
                    .disabled(!canOpenTransfer).accessibilityIdentifier("wireless.model.xe3")
                if selected == nil { savedCameraChoices }
                if selected != nil {
                    Button("Cancel") { setupStep = nil }
                }
            }
        }
        if !addingCamera && selected?.model == .xe3 {
            Button("Set up RAW transfer", action: onSetUpAutoSave)
                .disabled(!canOpenTransfer).accessibilityIdentifier("wireless.autoSave")
        }
        if !addingCamera && selected != nil {
            Menu {
                savedCameraChoices
                Button("Pair another camera", systemImage: "plus") { setupStep = .modelPicker }
                Button("Forget camera", systemImage: "trash", role: .destructive) { confirmingForget = true }
                    .accessibilityIdentifier("wireless.forget")
            } label: {
                Label("Manage cameras", systemImage: "ellipsis.circle")
            }
            .disabled(!canChoose).accessibilityIdentifier("wireless.change")
        }
    }

    private func modelChoice(_ name: String, route: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    Text(route).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var savedCameraChoices: some View {
        ForEach(state.savedCameras) { camera in
            if camera.id != selected?.id {
                Button(camera.displayName) {
                    connection.start(from: .status) { await model.selectWirelessCamera(camera.id) }
                }
                .disabled(!canChoose).accessibilityIdentifier(camera.selectionAccessibilityID)
            }
        }
    }

    @ViewBuilder private var connectionMessages: some View {
        if let rejection = state.firmwareRejection {
            Text(rejection.presentationGuidance).accessibilityIdentifier("wireless.firmware")
            if case .updateRequired = rejection.transferAdmission {
                Link("Fujifilm firmware update instructions",
                     destination: WirelessSupportPolicy().record(for: rejection.cameraModel).instructionsURL)
                    .accessibilityIdentifier("wireless.firmwareInstructions")
            }
        } else if let guidance = state.transferFailureGuidance {
            Text(guidance).accessibilityIdentifier("wireless.wifiFailure")
        }
        if state.cameraTransferSizeRestoreUnconfirmed {
            Text("Wi-Fi disconnected. The camera did not confirm that it restored its previous image transfer size.")
                .accessibilityIdentifier("wireless.transferSize")
        }
        if let failure = state.failure {
            Text(failure.connectionGuidance).accessibilityIdentifier("wireless.bluetoothFailure")
        }
        if state.pairingFailure == .unresolvedModel {
            Text("The camera model could not be verified. Start Pairing Registration on your X-T5 and try again.")
                .accessibilityIdentifier("wireless.bluetoothFailure")
        }
        if let error = model.wirelessActionError {
            Text(error).foregroundStyle(.red).accessibilityIdentifier("wireless.actionError")
        }
        if state.failure?.opensSettings == true || state.wifiFailure?.opensSettings == true {
            Button("Open Settings", action: model.openSettings).accessibilityIdentifier("wireless.settings")
        }
    }

    private func cancel() {
        setupStep = nil
        retryingBluetooth = false
        if connection.isWorking {
            connection.cancel { pending in await model.cancelWirelessConnection(draining: pending) }
        } else {
            Task { await model.cancelWirelessConnection(draining: nil) }
        }
    }

    private var disconnectButton: some View {
        Button("Disconnect WiFi") { Task { await model.disconnectCameraWiFi() } }
            .accessibilityIdentifier("wireless.disconnect")
    }
}

extension WirelessConnectionState {
    var transferFailureGuidance: String? {
        guard let wifiFailure else { return nil }
        if wifiFailurePhase == .disconnecting {
            return "The wireless session could not close safely. Tap Disconnect WiFi to retry."
        }
        return firmwareRejection?.presentationGuidance ?? wifiFailure.connectionGuidance
    }
}

extension WirelessBluetoothReadiness {
    var statusLabel: String {
        switch self {
        case .idle: "Bluetooth disconnected"
        case .discovering: "Looking for Bluetooth cameras…"
        case .pairing: "Pairing over Bluetooth…"
        case .connecting: "Reconnecting Bluetooth…"
        case .waitingForCamera: "Bluetooth waiting for camera"
        case .ready: "Bluetooth connected"
        case .unavailable: "Bluetooth unavailable"
        }
    }
}

extension WirelessWiFiPhase {
    var statusLabel: String {
        switch self {
        case .idle: "WiFi import disconnected"
        case .acquiringOwnership: "Preparing camera connection…"
        case .waitingForBluetooth: "Waiting for Bluetooth before joining WiFi…"
        case .bluetoothReady: "Bluetooth ready to start WiFi"
        case .activatingCamera: "Starting the camera’s WiFi…"
        case .joiningNetwork: "Joining the camera’s WiFi network…"
        case .registeringAutoSave: "Waiting for PC Auto Save registration…"
        case .verifyingAutoSave: "Verifying the camera’s PC Auto Save identity…"
        case .waitingForAutoSave: "Waiting for PC Auto Save to start on the camera…"
        case .openingSession: "WiFi joined. Opening the camera transfer session…"
        case .checkingFirmware: "Checking camera firmware…"
        case .loadingInventory: "Checking camera storage…"
        case .ready: "WiFi import connected"
        case .disconnecting: "Disconnecting WiFi…"
        }
    }
}

extension WirelessFailure {
    var opensSettings: Bool {
        if case .permissionDenied(let kind) = self { return kind != .wifiJoin }
        return false
    }

    var connectionGuidance: String {
        switch self {
        case .permissionDenied(.bluetooth):
            "Bluetooth access is required to pair and reconnect. Allow Bluetooth in Settings."
        case .permissionDenied(.localNetwork):
            "Local Network access is required to reach the camera. Allow Local Network in Settings."
        case .permissionDenied(.wifiJoin):
            "The camera’s WiFi network wasn’t joined. Try connecting again and approve Join."
        case .permissionDenied(.photos):
            "Allow Photos access in Settings to save and verify camera originals."
        case .authentication:
            "Bluetooth authentication failed. Retry Bluetooth or start pairing registration again."
        case .cameraBusy:
            "The camera is in use. Finish the current operation before connecting."
        case .usbCloseUnconfirmed:
            "The USB connection could not close safely. Reconnect the camera before starting wireless transfer."
        case .unsupportedFirmware:
            "The transfer session could not verify supported camera firmware."
        case .unsupportedProtocol:
            "The camera did not offer a supported wireless transfer mode."
        case .timeout(.autoSaveRegistration), .timeout(.autoSaveSession), .autoSavePeerUnreachable:
            "PC Auto Save could not reach the camera. Check that both devices are on the same WiFi network and confirm PC AUTO SAVE on the camera."
        case .timeout(.joinResult), .routeUnavailable:
            "The camera’s WiFi network is unreachable. Confirm the camera is ready and try connecting again."
        case .timeout(.savedReconnect), .timeout(.firstPairing), .timeout(.wifiReadiness):
            "The camera did not respond over Bluetooth. Wake it and check pairing registration."
        case .timeout(.tcpSetup), .timeout(.transactionInactivity), .connectionLost:
            "The camera connection was interrupted. Check that the camera is awake and reconnect."
        case .peerMismatch:
            "The transfer peer did not match the selected camera. Check which camera is connected."
        case .savedSettingsUnavailable:
            "Saved camera settings could not be read. Unlock your iPhone and reopen Fuji Studio to retry. For USB, use Reset camera connection in Status & settings."
        case .malformedData, .unavailableStorage:
            "Camera storage could not be read. Check the memory card and reconnect."
        case .objectChanged:
            "The card files changed. Reconnect and select photos again."
        case .inconsistentOriginalSizeObservations:
            "The camera reported conflicting original-size settings. On the camera, check that Resize Image for Smartphone is off, then reconnect."
        case .originalSizeUnavailable:
            "Original-size transfer could not be verified. On the camera, check that Resize Image for Smartphone is off, then reconnect."
        case .autoSaveEntitlementUnavailable:
            "This iPhone build cannot discover your X-E3 for PC Auto Save because it lacks Apple’s Multicast Networking capability."
        case .autoSaveIdentityUnavailable:
            "PC Auto Save requires a verified identity for this X-E3. RAW transfer through PC Auto Save is unavailable."
        case .autoSaveRegistrationRequired:
            "Register a PC Auto Save destination for this X-E3 before starting transfer."
        }
    }
}

extension WirelessFirmwareRejection {
    var presentationGuidance: String {
        switch transferAdmission {
        case .updateRequired:
            "Firmware update required. Update the \(cameraModel.rawValue) to firmware \(WirelessSupportPolicy().record(for: cameraModel).firmwareRequirement) before transferring originals."
        case .unverified(.newer):
            "The \(cameraModel.rawValue) reported newer firmware. Check for a Fuji Studio update before transferring originals."
        case .unverified(.unreadable):
            "The \(cameraModel.rawValue) firmware version could not be verified. Reconnect over WiFi to try again."
        case .supported where bluetoothRejectedFirmware:
            "The \(cameraModel.rawValue) transfer firmware was verified, but Bluetooth reported an unverified version. Reconnect Bluetooth and try again."
        case .supported, .unsupportedModel:
            "The camera’s transfer firmware could not be admitted. Original transfer is unavailable."
        }
    }
}

private extension DiscoveredCamera {
    var discoveryAccessibilityID: String {
        "wireless.discovered.\(advertisedModelHint?.rawValue ?? "unknown").\(peripheralID.uuidString)"
    }
}

private extension SavedCamera {
    var selectionAccessibilityID: String { "wireless.saved.\(model.rawValue).\(id.rawValue.uuidString)" }
}
