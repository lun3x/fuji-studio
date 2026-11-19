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
            if state.wifi == .registeringAutoSave {
                PairingInstructions([
                    "On the X-E3, select MANUAL SETUP.",
                    "Choose “SELECT FROM NETWORK LIST”.",
                    "Select the shared Wi-Fi network.",
                    "Enter its password if prompted.",
                    "Select the new PC destination."
                ], startingAt: 8, identifier: "wireless.autoSave.manual")
            } else if state.wifi == .waitingForAutoSave || state.wifi == .verifyingAutoSave {
                playbackSteps(startingAt: state.wifi == .waitingForAutoSave ? 2 : 13)
            }
            ProgressView(state.wifi.statusLabel)
                .accessibilityIdentifier("wireless.autoSave.progress")
            Button("Cancel", action: cancel)
                .disabled(model.isDisconnectingWireless || state.wifi == .disconnecting)
                .accessibilityIdentifier("wireless.cancel")
        } else {
            setupSteps
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

    @ViewBuilder private var setupSteps: some View {
        if registered && state.wifiFailure != .autoSaveRegistrationRequired {
            Text("Destination registered").font(.headline)
                .accessibilityIdentifier("wireless.autoSave.registered")
            if let destination = state.simulatorAutoSaveDestination {
                Text(destination).accessibilityIdentifier("wireless.autoSave.destination")
            }
            if state.hasAutomaticAutoSaveDestination {
                playbackSteps(startingAt: 1)
            } else {
                PairingStep(1) { waitForCamera.buttonStyle(.borderedProminent) }
                playbackSteps(startingAt: 2)
            }
        } else {
            PairingInstructions([
                state.simulatorAutoSaveAvailable
                    ? "Connect your Mac to the Wi-Fi network for the X-E3."
                    : "Connect your iPhone to the Wi-Fi network for the X-E3.",
                "Press MENU/OK on the X-E3.",
                "Select SET UP.",
                "Select CONNECTION SETTING.",
                "Select PC AUTO SAVE SETTINGS.",
                "Select PC AUTO SAVE SETTING."
            ], identifier: "wireless.autoSave.setup")
            PairingStep(7) {
                Button("Register destination") {
                    connection.start(from: .autoSave) { await model.setUpCameraAutoSave() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
                .accessibilityIdentifier("wireless.autoSave.register")
            }
            if allowsUnregisteredWait {
                Text("Already registered?").font(.subheadline)
                PairingStep(1) { waitForCamera.buttonStyle(.bordered) }
            }
        }
    }

    private func playbackSteps(startingAt first: Int) -> some View {
        PairingInstructions([
            "Press Playback on the X-E3.",
            "Press MENU/OK.",
            "Select PC AUTO SAVE.",
            "Select the saved destination.",
            "Confirm the transfer."
        ], startingAt: first, identifier: "wireless.autoSave.playback")
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
