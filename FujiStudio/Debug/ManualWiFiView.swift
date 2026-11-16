#if DEBUG
import FujiCameraCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ManualWiFiView: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var probe: ManualWiFiProbe?
  @State private var passwordCopied = false
  @State private var previousIdleTimer: Bool?

  var fixture = false

  var body: some View {
    NavigationStack {
      if let probe {
        ScrollViewReader { scroll in
          diagnosticForm(probe)
            .onChange(of: probe.galleryInProgress) { _, _ in
              scroll.scrollTo("manualWiFi.status", anchor: .top)
            }
            .onChange(of: probe.galleryResult != nil) { _, hasResult in
              if hasResult { scroll.scrollTo("manualWiFi.status", anchor: .top) }
            }
        }
      } else {
        ProgressView()
      }
    }
    .task {
      #if targetEnvironment(simulator)
      let withoutDeviceInfo = ProcessInfo.processInfo.environment["FUJI_FIXTURE_EMPTY_DEVICE_INFO"] == "1"
      let jpegOnly = ProcessInfo.processInfo.environment["FUJI_FIXTURE_JPEG_ONLY"] == "1"
      let current = fixture ? ManualWiFiFixture(withoutDeviceInfo: withoutDeviceInfo, jpegOnly: jpegOnly).probe
        : ManualWiFiProbe.live()
      #else
      let current = ManualWiFiProbe.live()
      #endif
      probe = current
      current.sceneChanged(scenePhase)
      await current.observe()
    }
    .onChange(of: scenePhase) { _, value in probe?.sceneChanged(value) }
    .onChange(of: probe?.keepsScreenAwake == true && scenePhase == .active) { _, running in
      keepScreenAwake(running)
    }
    .onDisappear {
      if probe?.galleryInProgress == true { probe?.cancel() }
      keepScreenAwake(false)
    }
  }

  private func diagnosticForm(_ probe: ManualWiFiProbe) -> some View {
    Form {
      Section {
        Text(probe.status)
          .id("manualWiFi.status")
          .accessibilityIdentifier("manualWiFi.status")
        if let progress = probe.scanProgress {
          TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let latest = progress.latest
            if let file = latest.file, let received = file.receivedBytes {
              ProgressView(value: Double(received), total: Double(file.expectedBytes)) {
                Text("\(file.role == .raf ? "RAF" : "JPEG"): \(received.formatted()) of \(file.expectedBytes.formatted()) bytes")
              }
            } else if let card = latest.card, let total = card.totalHandles {
              ProgressView {
                Text("Card \(card.slot): scanned \(card.scannedCount) of \(total)")
              }
            } else {
              ProgressView("Opening the camera gallery…")
            }
          }
        }
      } header: {
        Text("X-T5 connection diagnostic")
      } footer: {
        Text("Temporary test for X-T5 firmware 4.30 or later. It checks the connection, scans available cards, and can test one JPEG+RAW download.")
      }
      if let result = probe.galleryResult {
        galleryResults(result)
      }
      if let mode = probe.registrationMode {
        Section("Check registration on the camera") {
          let destination = ManualWiFiBluetoothDriver.phoneDestinationName
          if mode == .pair {
            Text("On the camera, check that pairing completed and that \(destination) appears in Select Pairing Destination. Select that destination.")
          } else {
            Text("On the camera, select \(destination) in Select Pairing Destination. If that name is absent, cancel and choose Pair a new camera.")
          }
          Button(probe.registrationConfirmed ? "Camera registration confirmed" : "I verified \(destination) on the camera") {
            probe.confirmRegistration()
          }
          .accessibilityIdentifier("manualWiFi.confirmRegistration")
          .disabled(!probe.canConfirmRegistration)
          Button("Start camera Wi-Fi") { probe.startWiFi() }
            .accessibilityIdentifier("manualWiFi.startWiFi")
            .disabled(!probe.canStartWiFi)
        }
      }
      if let network = probe.handoff, scenePhase == .active {
        Section("Join the camera network") {
          Text("In Settings → Wi-Fi, choose this network. If it is hidden, tap Other, enter the name exactly and choose WPA2 if prompted for security.")
          LabeledContent("Network name", value: network.ssid)
            .privacySensitive()
          if let password = probe.visiblePassword {
            LabeledContent("Password") {
              Button {
                guard scenePhase == .active, probe.visiblePassword == password else { return }
                UIPasteboard.general.setItems(
                  [[UTType.utf8PlainText.identifier: password]],
                  options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(5 * 60)]
                )
                passwordCopied = true
                AccessibilityNotification.Announcement("Password copied").post()
              } label: {
                Label(password, systemImage: "document.on.document")
                  .labelStyle(.titleAndIcon)
              }
              .buttonStyle(.borderless)
              .accessibilityLabel("Copy password")
              .accessibilityValue(Text(password))
              .accessibilityHint("Copies the Wi-Fi password to the clipboard")
              .accessibilityIdentifier("manualWiFi.password")
            }
            .privacySensitive()
            if passwordCopied {
              Text("Copied")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("manualWiFi.passwordCopied")
            }
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
          Button("Check camera connection") { probe.identify() }
            .accessibilityIdentifier("manualWiFi.identify")
            .disabled(!probe.canIdentify)
          Button("Scan all photos") { probe.listCameraPhotos() }
            .accessibilityIdentifier("manualWiFi.listPhotos")
            .disabled(!probe.canListPhotos)
          Button("Test JPEG+RAW download") { probe.testPairDownload() }
            .accessibilityIdentifier("manualWiFi.testPair")
            .disabled(!probe.canListPhotos)
          Text("Allow Local Network access and confirm on the camera if prompted. The scan reads all available metadata. The download test scans first, validates one pair in app-private storage, and closes the connection.")
        }
      }
      Section("Camera selection") {
        Button("Find paired X-T5") { probe.findPairedCamera() }
          .accessibilityIdentifier("manualWiFi.findPaired")
          .disabled(!probe.canScan)
        Text("On the camera, turn Bluetooth on, select Fuji iPhone in Select Pairing Destination, then return the camera to normal shooting.")
        ForEach(probe.pairedNearby) { camera in
          Button("Reconnect to nearby \(camera.displayName) (\(localLabel(camera, in: probe)))") {
            probe.reconnectNearby(camera)
          }
          .accessibilityIdentifier("manualWiFi.pairedCamera")
          .disabled(!probe.canReconnect)
        }
        Button("Pair a new camera") { probe.scanForPairing() }
          .accessibilityIdentifier("manualWiFi.newPairing")
          .disabled(!probe.canScan)
        ForEach(probe.discovered) { camera in
          Button("Pair with \(camera.displayName)") { probe.connect(.discovered(camera)) }
            .disabled(!probe.canSelect)
        }
        if !probe.saved.isEmpty {
          DisclosureGroup("Local saved records") {
            ForEach(probe.saved) { camera in
              let linked = probe.linkedRecordID == camera.id ? ", linked" : ""
              Button("Reconnect to \(camera.displayName) (\(localLabel(camera, in: probe))\(linked))") {
                probe.connect(.saved(camera))
              }
              .disabled(!probe.canReconnect)
            }
          }
        }
      }
    }
    .onChange(of: probe.visiblePassword != nil) { _, _ in passwordCopied = false }
    .navigationTitle("Fuji Manual WiFi")
    .toolbar {
      if probe.canCancel {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { probe.cancel() }
        }
      }
    }
  }

  private func keepScreenAwake(_ running: Bool) {
    if running, previousIdleTimer == nil {
      previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
      UIApplication.shared.isIdleTimerDisabled = true
    } else if !running, let previousIdleTimer {
      UIApplication.shared.isIdleTimerDisabled = previousIdleTimer
      self.previousIdleTimer = nil
    }
  }

  @ViewBuilder
  private func galleryResults(_ result: XAppGalleryDiagnosticResult) -> some View {
    ForEach(result.cards, id: \.summary.slot) { card in
      Section {
        if let total = card.summary.totalHandles {
          Text("Scanned \(card.summary.scannedCount) of \(total) objects: \(card.summary.jpegCount) JPEG, \(card.summary.rafCount) RAF, \(card.summary.otherCount) other.")
          ForEach(Array(card.samples.enumerated()), id: \.offset) { _, sample in
            LabeledContent {
              Text("\(formatLabel(sample.format)) · \(sample.byteLength.formatted()) bytes")
            } label: {
              Text(verbatim: sample.filename).privacySensitive()
            }
          }
        } else {
          Text("Unavailable")
        }
      } header: {
        Text("Card \(card.summary.slot)")
      } footer: {
        if let total = card.summary.totalHandles, total > 0 {
          Text("Showing the first \(card.samples.count) of \(total) objects in camera order.")
        }
      }
    }
  }

  private func formatLabel(_ format: WirelessObjectFormat) -> String {
    switch format {
    case .jpeg: "JPEG"
    case .raf: "RAF"
    case .other: "Other"
    }
  }

  private func localLabel(_ camera: SavedCamera, in probe: ManualWiFiProbe) -> String {
    let index = probe.saved.firstIndex { $0.id == camera.id } ?? 0
    return "local record \(index + 1)"
  }
}
#endif
