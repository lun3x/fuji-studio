#if DEBUG
import SwiftUI

struct ManualWiFiView: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var probe: ManualWiFiProbe?

  var fixture = false

  var body: some View {
    NavigationStack {
      if let probe {
        Form {
          Section {
            Text(probe.status).accessibilityIdentifier("manualWiFi.status")
          } header: {
            Text("X-T5 identity diagnostic")
          } footer: {
            Text("Temporary test for X-T5 firmware 4.30 or later. It reads the model and firmware without transferring photos.")
          }
          if let network = probe.handoff, scenePhase == .active {
            Section("Join the camera network") {
              Text("In Settings → Wi-Fi, choose this network. If it is hidden, tap Other, enter the name exactly and choose WPA2 if prompted for security.")
              LabeledContent("Network name", value: network.ssid)
                .privacySensitive()
              if let password = probe.visiblePassword {
                LabeledContent("Password") {
                  Text(password).accessibilityIdentifier("manualWiFi.password")
                }
                .privacySensitive()
              }
              Button(probe.visiblePassword == nil ? "Reveal password" : "Hide password") {
                probe.revealPassword()
              }
              .accessibilityIdentifier("manualWiFi.reveal")
              Text("If iOS asks, stay connected to the network without internet. Return promptly. The handoff can expire after about 25 seconds in Settings.")
              Button(probe.userConfirmed ? "Network confirmed by you" : "I joined this network in Settings") {
                probe.confirmJoined()
              }
              .accessibilityIdentifier("manualWiFi.confirm")
              .disabled(!probe.canConfirm)
              Text("You confirm the network. This diagnostic cannot check its name in iOS.")
              Button("Test camera identity") { probe.identify() }
                .accessibilityIdentifier("manualWiFi.identify")
                .disabled(!probe.canIdentify)
              Text("If prompted, allow Local Network access. The result verifies the model and firmware reported over Wi-Fi.")
            }
          }
          Section("Camera selection") {
            ForEach(probe.saved) { camera in
              Button("Reconnect to \(camera.displayName)") { probe.connect(.saved(camera)) }
                .accessibilityIdentifier("manualWiFi.savedCamera")
                .disabled(!probe.canSelect)
            }
            Button("Discover Bluetooth cameras") { probe.scan() }
              .disabled(!probe.canScan)
            ForEach(probe.discovered) { camera in
              Button("Pair with \(camera.displayName)") { probe.connect(.discovered(camera)) }
                .disabled(!probe.canSelect)
            }
          }
        }
        .navigationTitle("Fuji Manual WiFi")
        .toolbar {
          if probe.canCancel {
            ToolbarItem(placement: .cancellationAction) {
              Button("Cancel") { probe.cancel() }
            }
          }
        }
      } else {
        ProgressView()
      }
    }
    .task {
      #if targetEnvironment(simulator)
      let current = fixture ? ManualWiFiFixture().probe : ManualWiFiProbe.live()
      #else
      let current = ManualWiFiProbe.live()
      #endif
      probe = current
      current.sceneChanged(scenePhase)
      await current.observe()
    }
    .onChange(of: scenePhase) { _, value in probe?.sceneChanged(value) }
  }
}
#endif
