import FujiCameraCore
import SwiftUI

struct AutoSaveSetupView: View {
    let model: AppModel
    let onBack: () -> Void
    let onBrowse: () -> Void
    @State private var availability: Result<Void, WirelessFailure>?

    private var state: WirelessConnectionState { model.wirelessState }
    private var isBusy: Bool { state.wifi != .idle && state.wifi != .ready }
    private var registered: Bool {
        guard let id = state.selectedCameraID else { return false }
        return state.verifiedAutoSaveCameraID == id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("PC Auto Save").font(.headline).accessibilityAddTraits(.isHeader)
                Text("Connect your iPhone and X-E3 to the same WiFi network. PC Auto Save uses that shared network.")
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
            Text("PC Auto Save destination verified").font(.headline)
                .accessibilityIdentifier("wireless.autoSave.registered")
        } else {
            Text("On the X-E3, open CONNECTION SETTING → PC AUTO SAVE SETTINGS → PC AUTO SAVE SETTING. Tap Register destination here, then choose MANUAL SETUP on the camera. Choose the shared WiFi network and select Fuji Studio when it appears.")
                .accessibilityIdentifier("wireless.autoSave.setupInstructions")
        }
        if registered || state.wifiFailure != .autoSaveRegistrationRequired {
            Text(registered
                ? "Tap Wait for camera, then open the X-E3 playback menu, choose PC AUTO SAVE and start the transfer to Fuji Studio."
                : "Already set up? Tap Wait for camera, then start PC AUTO SAVE from the X-E3 playback menu.")
                .accessibilityIdentifier("wireless.autoSave.startInstructions")
        }
        if state.wifi == .ready && !model.isDisconnectingWireless {
            Button("Browse camera photos", action: onBrowse).buttonStyle(.borderedProminent)
                .accessibilityIdentifier("wireless.browse")
        } else if isBusy || model.isDisconnectingWireless {
            ProgressView(state.wifi.statusLabel)
                .accessibilityIdentifier("wireless.autoSave.progress")
            Button("Cancel") { Task { await model.cancelWirelessConnection() } }
                .disabled(model.isDisconnectingWireless || state.wifi == .disconnecting)
                .accessibilityIdentifier("wireless.cancel")
        } else {
            transferActions
        }
        if let failure = state.wifiFailure,
           state.wifiFailurePhase == .registeringAutoSave || state.wifiFailurePhase == .waitingForAutoSave
            || state.wifiFailurePhase == .verifyingAutoSave || state.wifiFailurePhase == .checkingFirmware {
            Text(state.firmwareRejection?.presentationGuidance ?? failure.connectionGuidance)
                .accessibilityIdentifier("wireless.autoSave.failure")
            if failure.opensSettings {
                Button("Open Settings", action: model.openSettings)
                    .accessibilityIdentifier("wireless.autoSave.settings")
            }
        }
    }

    private var canStart: Bool {
        !model.state.wirelessRestrictsUSB && !model.cameraImportActive && !model.isSuspended
    }

    @ViewBuilder private var transferActions: some View {
        if !registered || state.wifiFailure == .autoSaveRegistrationRequired {
            Button("Register destination") { Task { await model.setUpCameraAutoSave() } }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
                .accessibilityIdentifier("wireless.autoSave.register")
        }
        if state.wifiFailure != .autoSaveRegistrationRequired {
            if registered {
                waitForCamera.buttonStyle(.borderedProminent)
            } else {
                waitForCamera.buttonStyle(.bordered)
            }
        }
    }

    private var waitForCamera: some View {
        Button("Wait for camera") { Task { await model.waitForCameraAutoSave() } }
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
        if isBusy { Task { await model.cancelWirelessConnection() } }
        onBack()
    }
}
