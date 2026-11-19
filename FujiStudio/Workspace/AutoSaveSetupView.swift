import FujiCameraCore
import SwiftUI

struct AutoSaveSetupView: View {
    let model: AppModel
    let connection: PresentedCameraConnection
    let onBack: () -> Void
    let onBrowse: () -> Void

    var body: some View {
        ScrollView {
            AutoSaveSetupContent(model: model, connection: connection, onBrowse: onBrowse)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("X-E3 PC Auto Save")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CameraFlowBackButton(label: "Back to status and settings", identifier: "wireless.autoSave.done") {
                    if connection.isWorking {
                        connection.cancel(from: .autoSave) { await model.cancelWirelessConnection(draining: $0) }
                    }
                    onBack()
                }
            }
        }
    }
}

struct AutoSaveSetupContent: View {
    let model: AppModel
    let connection: PresentedCameraConnection
    let onBrowse: () -> Void
    @State private var availability: Result<Void, WirelessFailure>?

    private var state: WirelessConnectionState { model.wirelessState }
    private var isBusy: Bool { connection.isWorking || state.wifi != .idle && state.wifi != .ready }
    private var registered: Bool {
        guard let id = state.selectedCameraID else { return false }
        return state.verifiedAutoSaveCameraID == id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch availability {
            case nil:
                ProgressView("Checking availability…")
            case .failure(let failure):
                Text(failure.connectionGuidance).accessibilityIdentifier("wireless.autoSave.unavailable")
                if failure.opensSettings {
                    Button("Open Settings", action: model.openSettings)
                        .accessibilityIdentifier("wireless.autoSave.settings")
                    Button("Check availability") { Task { await checkAvailability() } }
                        .accessibilityIdentifier("wireless.autoSave.check")
                }
            case .success:
                registration
            }
        }
        .task(id: state.selectedCameraID) { await checkAvailability() }
    }

    @ViewBuilder private var registration: some View {
        if state.wifi == .ready && !model.isDisconnectingWireless {
            Button("Browse camera photos", action: onBrowse).buttonStyle(.borderedProminent)
                .accessibilityIdentifier("wireless.browse")
        } else if state.wifi == .idle && state.hasTransferLease && !model.isDisconnectingWireless {
            Button("Disconnect WiFi") { Task { await model.disconnectCameraWiFi() } }
                .accessibilityIdentifier("wireless.disconnect")
        } else if isBusy || model.isDisconnectingWireless {
            ProgressView(state.wifi.statusLabel)
                .accessibilityIdentifier("wireless.autoSave.progress")
            Button("Cancel", action: cancel)
                .disabled(model.isDisconnectingWireless || state.wifi == .disconnecting)
                .accessibilityIdentifier("wireless.cancel")
        } else {
            setupGuidance
            transferActions
        }
        if state.transferRoute == .autoSave, let failure = state.wifiFailure, let guidance = state.transferFailureGuidance {
            Text(guidance)
                .accessibilityIdentifier("wireless.autoSave.failure")
            if failure.opensSettings {
                Button("Open Settings", action: model.openSettings)
                    .accessibilityIdentifier("wireless.autoSave.settings")
            }
        }
    }

    private var canStart: Bool {
        !connection.isWorking && !model.state.wirelessRestrictsUSB && !model.cameraImportActive && !model.isSuspended
    }

    @ViewBuilder private var setupGuidance: some View {
        if registered {
            Text("Destination registered").font(.headline)
                .accessibilityIdentifier("wireless.autoSave.registered")
            if let destination = state.simulatorAutoSaveDestination {
                Text(destination).accessibilityIdentifier("wireless.autoSave.destination")
            }
            Text(transferInstructions).accessibilityIdentifier("wireless.autoSave.startInstructions")
        } else {
            Text(state.simulatorAutoSaveAvailable
                ? "Connect your Mac and X-E3 to the same WiFi network."
                : "Connect your iPhone and X-E3 to the same WiFi network.")
                .accessibilityIdentifier("wireless.autoSave.network")
            Text(setupInstructions).accessibilityIdentifier("wireless.autoSave.setupInstructions")
            if allowsUnregisteredWait {
                Text("Already registered? Tap Wait for camera, then start PC AUTO SAVE in the playback menu.")
                    .accessibilityIdentifier("wireless.autoSave.startInstructions")
            }
        }
    }

    private var setupInstructions: String {
        "On the X-E3, open PC AUTO SAVE SETTING. Tap Register destination, then choose MANUAL SETUP on the camera."
    }

    private var transferInstructions: String {
        if state.hasAutomaticAutoSaveDestination {
            return "Start PC AUTO SAVE in the X-E3 playback menu."
        }
        return "Tap Wait for camera, then choose PC AUTO SAVE in the playback menu."
    }

    @ViewBuilder private var transferActions: some View {
        if !registered || state.wifiFailure == .autoSaveRegistrationRequired {
            Button("Register destination") {
                connection.start(from: .autoSave) { await model.setUpCameraAutoSave() }
            }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
                .accessibilityIdentifier("wireless.autoSave.register")
        }
        if state.wifiFailure != .autoSaveRegistrationRequired,
           !state.hasAutomaticAutoSaveDestination && (registered || allowsUnregisteredWait) {
            if registered {
                waitForCamera.buttonStyle(.borderedProminent)
            } else {
                waitForCamera.buttonStyle(.bordered)
            }
        }
    }

    private var allowsUnregisteredWait: Bool {
        !state.simulatorAutoSaveAvailable && state.wifiFailure != .autoSaveRegistrationRequired
    }

    private var waitForCamera: some View {
        Button("Wait for camera") {
            connection.start(from: .autoSave) { await model.waitForCameraAutoSave() }
        }
            .disabled(!canStart)
            .accessibilityIdentifier("wireless.autoSave.wait")
    }

    private func checkAvailability() async {
        do {
            try await model.checkCameraAutoSaveAvailability()
            guard !Task.isCancelled else { return }
            availability = .success(())
        } catch {
            guard !Task.isCancelled else { return }
            availability = .failure(error as? WirelessFailure ?? .autoSaveIdentityUnavailable)
        }
    }

    private func cancel() {
        if connection.isWorking {
            connection.cancel(from: .autoSave) { pending in await model.cancelWirelessConnection(draining: pending) }
        } else {
            Task { await model.cancelWirelessConnection(draining: nil) }
        }
    }
}
