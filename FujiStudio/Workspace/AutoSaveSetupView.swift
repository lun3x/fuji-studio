import FujiCameraCore
import SwiftUI

struct AutoSaveSetupView: View {
    let model: AppModel
    let connection: PresentedCameraConnection
    let onBack: () -> Void
    let onBrowse: () -> Void
    @State private var availability: Result<Void, WirelessFailure>?

    private var state: WirelessConnectionState { model.wirelessState }
    private var isBusy: Bool { connection.isWorking || state.wifi != .idle && state.wifi != .ready }
    private var registered: Bool {
        guard let id = state.selectedCameraID else { return false }
        return state.verifiedAutoSaveCameraID == id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("PC Auto Save").font(.headline).accessibilityAddTraits(.isHeader)
                Text(state.simulatorAutoSaveAvailable
                    ? "Connect your Mac and X-E3 to the same WiFi network."
                    : "Connect your iPhone and X-E3 to the same WiFi network. PC Auto Save uses that shared network.")
                    .accessibilityIdentifier("wireless.autoSave.network")
                switch availability {
                case nil:
                    ProgressView("Checking PC Auto Save availability…")
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Set up RAW transfer")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CameraFlowBackButton(label: "Back to status and settings", identifier: "wireless.autoSave.done") {
                    back()
                }
            }
        }
        .task(id: state.selectedCameraID) { await checkAvailability() }
    }

    @ViewBuilder private var registration: some View {
        if registered {
            Text(state.simulatorAutoSaveAvailable
                ? "PC Auto Save destination registered" : "PC Auto Save destination verified").font(.headline)
                .accessibilityIdentifier("wireless.autoSave.registered")
            if let destination = state.simulatorAutoSaveDestination {
                Text(destination).accessibilityIdentifier("wireless.autoSave.destination")
            }
        } else {
            Text(setupInstructions)
                .accessibilityIdentifier("wireless.autoSave.setupInstructions")
        }
        if registered || allowsUnregisteredWait {
            Text(registered
                ? "Tap Wait for camera, then open the X-E3 playback menu, choose PC AUTO SAVE and start the transfer to Fuji Studio."
                : "Already set up? Tap Wait for camera, then start PC AUTO SAVE from the X-E3 playback menu.")
                .accessibilityIdentifier("wireless.autoSave.startInstructions")
        }
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

    private var setupInstructions: String {
        let start = "On the X-E3, open CONNECTION SETTING → PC AUTO SAVE SETTINGS → PC AUTO SAVE SETTING. Tap Register destination here, then choose MANUAL SETUP on the camera."
        if state.simulatorAutoSaveAvailable {
            return start + " Choose the shared WiFi network and select the new PC destination when it appears."
        }
        return start + " Choose the shared WiFi network and select Fuji Studio when it appears."
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
        if state.wifiFailure != .autoSaveRegistrationRequired && (registered || allowsUnregisteredWait) {
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

    private func back() {
        cancel()
        onBack()
    }

    private func cancel() {
        connection.cancel(from: .autoSave) { pending in await model.cancelWirelessConnection(draining: pending) }
    }
}
