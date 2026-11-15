import FujiCameraCore
import SwiftUI

struct CameraConnectionSection: View {
    let model: AppModel
    let connection: PresentedCameraConnection
    let onBrowse: () -> Void
    let onSetUpAutoSave: () -> Void
    @State private var choosingCamera = false
    @State private var confirmingForget = false
    @State private var retryingBluetooth = false

    private var state: WirelessConnectionState { model.wirelessState }
    private var selected: SavedCamera? { state.savedCameras.first { $0.id == state.selectedCameraID } }
    private var discovering: Bool { state.bluetooth == .discovering || state.bluetooth == .pairing }
    private var connected: Bool { state.wifi == .ready && !model.isDisconnectingWireless }
    private var disconnecting: Bool { state.wifi == .disconnecting || model.isDisconnectingWireless }
    private var unconfirmedClose: Bool { state.wifi == .idle && state.hasTransferLease }
    private var canChoose: Bool { !model.state.wirelessRestrictsUSB && !discovering && !connection.isWorking }
    private var canOpenTransfer: Bool { canChoose && !model.isSuspended && !model.cameraImportActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wireless camera").font(.headline).accessibilityAddTraits(.isHeader)
            if let selected {
                Text(selected.displayName).accessibilityIdentifier("wireless.selected")
            }
            Label(state.bluetooth.statusLabel, systemImage: "antenna.radiowaves.left.and.right")
                .accessibilityIdentifier("wireless.bluetooth")
            Label(wifiStatus, systemImage: "wifi")
                .accessibilityIdentifier("wireless.wifi")
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
                    Text("Start pairing registration in the camera’s connection settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(state.discoveredCameras) { camera in
                        Button(camera.displayName) {
                            connection.start(from: .status) { await model.pairWirelessCamera(camera) }
                        }
                            .disabled(connection.isWorking)
                            .accessibilityIdentifier(camera.discoveryAccessibilityID)
                    }
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
                Task { await model.forgetWirelessCamera(camera.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { camera in
            Text("Pair \(camera.displayName) again to reconnect over Bluetooth.")
        }
        .onChange(of: state.bluetooth) { _, readiness in
            if readiness != .connecting { retryingBluetooth = false }
        }
    }

    private var wifiStatus: String {
        if disconnecting { return WirelessWiFiPhase.disconnecting.statusLabel }
        return unconfirmedClose ? "WiFi closure unconfirmed" : state.wifi.statusLabel
    }

    @ViewBuilder private var connectionActions: some View {
        if let selected {
            Button("Connect over WiFi") {
                connection.start(from: .status) { await model.connectCameraWiFi() }
            }
                .buttonStyle(.borderedProminent)
                .disabled(!canOpenTransfer)
                .accessibilityIdentifier("wireless.connect")
            if selected.model == .xe3 {
                Button("Set up RAW transfer", action: onSetUpAutoSave)
                    .disabled(!canOpenTransfer).accessibilityIdentifier("wireless.autoSave")
            }
        }
        if state.bluetooth == .unavailable || state.bluetooth == .waitingForCamera {
            if selected != nil {
                Button("Retry Bluetooth") {
                    retryingBluetooth = true
                    connection.start(from: .status) { await model.retryCameraBluetooth() }
                }
                    .disabled(!canChoose).accessibilityIdentifier("wireless.retry")
            }
        }
        if selected == nil || choosingCamera {
            ForEach(state.savedCameras) { camera in
                if camera.id != selected?.id {
                    Button(camera.displayName) {
                        choosingCamera = false
                        connection.start(from: .status) { await model.selectWirelessCamera(camera.id) }
                    }
                    .disabled(!canChoose)
                    .accessibilityIdentifier(camera.selectionAccessibilityID)
                }
            }
            Button("Pair camera") {
                connection.start(from: .status) { await model.discoverWirelessCameras() }
            }
                .disabled(!canChoose).accessibilityIdentifier("wireless.pair")
        }
        if selected != nil {
            Button(choosingCamera ? "Done changing camera" : "Change camera") { choosingCamera.toggle() }
                .disabled(!canChoose).accessibilityIdentifier("wireless.change")
            Button("Forget camera", role: .destructive) { confirmingForget = true }
                .disabled(!canChoose).accessibilityIdentifier("wireless.forget")
        }
    }

    @ViewBuilder private var connectionMessages: some View {
        if let rejection = state.firmwareRejection {
            Text(rejection.presentationGuidance).accessibilityIdentifier("wireless.firmware")
        } else if let guidance = state.transferFailureGuidance {
            Text(guidance).accessibilityIdentifier("wireless.wifiFailure")
        }
        if let failure = state.failure {
            Text(failure.connectionGuidance).accessibilityIdentifier("wireless.bluetoothFailure")
        }
        if state.pairingFailure == .unresolvedModel {
            Text("The camera model could not be verified. Start pairing registration on a supported X-T5 or X-E3 and try again.")
                .accessibilityIdentifier("wireless.bluetoothFailure")
        }
        if let error = model.wirelessActionError {
            Text(error).foregroundStyle(.red).accessibilityIdentifier("wireless.actionError")
        }
        if state.failure?.opensSettings == true || state.wifiFailure?.opensSettings == true {
            Button("Open Settings", action: model.openSettings).accessibilityIdentifier("wireless.settings")
        }
        if model.state.wirelessRestrictsUSB {
            Text("Disconnect WiFi to use USB conversion.")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("wireless.usbUnavailable")
        }
    }

    private func cancel() {
        choosingCamera = false
        retryingBluetooth = false
        connection.cancel { pending in await model.cancelWirelessConnection(draining: pending) }
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
        case .malformedData, .unavailableStorage:
            "Camera storage could not be read. Check the memory card and reconnect."
        case .objectChanged:
            "The card files changed. Reconnect and select photos again."
        case .originalSizeUnavailable:
            "The camera’s original-size transfer could not be verified. RAW import is unavailable in this session."
        case .autoSaveEntitlementUnavailable:
            "PC Auto Save RAW transfer is unavailable in this build. Local network discovery requires Apple’s Multicast Networking capability."
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
        case .updateRequired(let version):
            "Firmware update required. Update the \(cameraModel.rawValue) to firmware \(version) before transferring originals."
        case .unverified(let version):
            if let version {
                "Firmware version \(version) on the \(cameraModel.rawValue) is unverified for this release. Original transfer is unavailable."
            } else {
                "The \(cameraModel.rawValue) firmware version could not be read. Original transfer is unavailable."
            }
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
