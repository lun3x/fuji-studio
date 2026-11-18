import SwiftUI
import UIKit

struct CameraNetworkInstructions: View {
    let network: CameraNetwork
    let connection: WirelessConnectionCoordinator
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var password: String?
    @State private var copied = false
    @State private var failed = false
    @State private var settingsUnavailable = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Network", value: network.ssid)
                        .privacySensitive()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Network").accessibilityValue(network.ssid)
                        .accessibilityIdentifier("cameraNetwork.ssid")
                    if phase == .active, let password {
                        LabeledContent("Password") {
                            Text(password).font(.body.monospaced()).textSelection(.enabled).privacySensitive()
                            Button {
                                UIPasteboard.general.setItems([["public.utf8-plain-text": password]],
                                    options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(180)])
                                copied = true
                            } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc") }
                            .buttonStyle(.borderless).accessibilityLabel(copied ? "Password copied" : "Copy password")
                            .accessibilityValue(password).accessibilityIdentifier("cameraNetwork.copy")
                        }.accessibilityElement(children: .contain)
                    } else if failed {
                        Text("Couldn’t read the camera password. Disconnect and try again.")
                    }
                } footer: {
                    Text("In Settings, open Wi-Fi and join this network. If it’s hidden, tap Other, enter the network name, and choose WPA2. Stay connected if iPhone reports no internet, then return to Fuji Studio.")
                }
                if settingsUnavailable {
                    Text("From the Home Screen, open Settings, then tap Wi-Fi.")
                } else {
                    Button("Open Settings") {
                        // iOS may route this to the main Settings screen, or decline the handoff.
                        openURL(URL(string: "App-Prefs:root=WIFI")!) { opened in
                            if !opened {
                                openURL(URL(string: "App-Prefs:")!) { settingsUnavailable = !$0 }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Join camera Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Dismiss") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
        .task(id: phase) {
            password = nil
            guard phase == .active else { return }
            do {
                let value = try await connection.handoffPassword(for: network)
                if !Task.isCancelled { password = value; failed = false }
            } catch { failed = true }
        }
    }
}
