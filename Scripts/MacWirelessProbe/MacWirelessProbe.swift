import AppKit
import CoreBluetooth
import Darwin
import Foundation
import FujiCameraCore

@main
struct MacWirelessProbe {
  @MainActor
  static func main() {
    umask(0o077)
    let arguments = CommandLine.arguments
    guard arguments.count == 3, arguments[1] == "--run-dir",
      let directory = try? RunDirectory(path: arguments[2])
    else {
      fputs("Launch MacWirelessProbe with --run-dir and a fresh owner-only directory.\n", stderr)
      exit(2)
    }

    let app = NSApplication.shared
    let probe = WirelessProbe(directory: directory)
    app.setActivationPolicy(.regular)
    app.delegate = probe
    withExtendedLifetime(probe) { app.run() }
  }
}

@MainActor
private final class WirelessProbe: NSObject, NSApplicationDelegate {
  private enum Phase: String {
    case idle, discovering, pairing, reconnecting, linked, activatingWiFi, disconnecting, stopped
  }

  private let directory: RunDirectory
  private let store: KeychainCameraStore
  private let gateway: NativeBluetoothGateway
  private let statusView = NSTextField(wrappingLabelWithString: "")
  private var window: NSWindow?
  private var timer: Timer?
  private var scan: Task<Void, Never>?
  private var operation: Task<Void, Never>?
  private var phase = Phase.idle
  private var shutdownRequested = false
  private var availability = "uninitialized"
  private var result = "waiting"
  private var lastCommand = "none"
  private var candidates: [Int: DiscoveredCamera] = [:]
  private var nextHandle = 1
  private var selectedHandle: Int?
  private var verifiedPairingSession: UUID?
  private var linkedCamera: SavedCamera?
  private var savedModel: WirelessCameraModel?
  private var cameraNetwork: CameraNetwork?
  private var messages: [String] = []
  private var previousStatus: String?

  init(directory: RunDirectory) {
    self.directory = directory
    let service = "com.lun3x.FujiStudio.MacWirelessProbe.camera"
    let keychain = ProbeKeychain()
    store = KeychainCameraStore(
      defaults: UserDefaults(suiteName: service)!, service: service, keychain: keychain)
    let driver = CoreBluetoothDriver()
    gateway = NativeBluetoothGateway(store: store, driver: driver)
    super.init()

    keychain.observe = { [weak self] event in self?.record(event) }
    driver.observePairing = { [weak self] event in self?.record(event) }
    driver.observeUnrecognizedModel = { [weak self] model in self?.captureUnknownModel(model) }

    // Preserve the production link and profile. Only first pairing on this
    // test rig has a stricter admission rule: DIS must report X-T5.
    let forward = driver.eventHandler
    driver.eventHandler = { [weak self] event in
      guard let self else { return }
      switch event {
      case .availability(let availability):
        self.record("Driver reported Bluetooth \(availability)")
      case .peerModel(let session, let value) where self.phase == .pairing:
        if value.flatMap(WirelessCameraModel.init(bluetoothModelNumber:)) == .xt5 {
          self.verifiedPairingSession = session
        }
      case .protocolEvent(let session, .services) where self.phase == .pairing:
        guard self.verifiedPairingSession == session else {
          self.record("Pairing requires a verified X-T5 Device Information model")
          forward?(.linkFailed(session, .unsupportedProtocol))
          return
        }
      default:
        break
      }
      forward?(event)
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let frame = NSRect(x: 0, y: 0, width: 460, height: 300)
    let window = NSWindow(
      contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "MacWirelessProbe"
    window.isReleasedWhenClosed = false
    statusView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    statusView.isSelectable = true
    statusView.translatesAutoresizingMaskIntoConstraints = false
    if let content = window.contentView {
      content.addSubview(statusView)
      NSLayoutConstraint.activate([
        statusView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
        statusView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        statusView.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
      ])
    }
    self.window = window
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()

    record("Idle. Awaiting an explicit command.")
    publish()
    let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer

    Task {
      record("Gateway event observer started")
      for await event in await gateway.events() {
        switch event {
        case .availability(let state):
          availability = String(describing: state)
          record("Bluetooth \(availability)")
          publish()
        case .disconnected(let id, let failure):
          guard linkedCamera?.id == id, phase == .linked || phase == .activatingWiFi else {
            continue
          }
          linkedCamera = nil
          let label = Self.failureLabel(failure)
          if phase == .activatingWiFi || cameraNetwork != nil {
            // A body may close BLE while its access point starts. The
            // gateway's activation result still determines Wi-Fi readiness.
            if phase == .linked { phase = .idle }
            record("BLE disconnected during Wi-Fi test: \(label)")
            publish()
          } else {
            finish(label, phase: .idle)
          }
        }
      }
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard phase != .stopped else { return .terminateNow }
    disconnect(shutdown: true)
    return .terminateLater
  }

  private func poll() {
    do {
      guard let command = try directory.nextCommand() else { return }
      let words = command.split(separator: " ")
      switch (words.first, words.count) {
      case ("discover", 1): discover()
      case ("select", 2): select(Int(words[1]))
      case ("pair", 1): pair()
      case ("disconnect", 1): disconnect()
      case ("reconnect", 1): reconnect()
      case ("wifi", 1): activateWiFi()
      case ("quit", 1): NSApp.terminate(nil)
      default: reject("unknown", "invalidCommand")
      }
    } catch RunDirectory.Failure.invalidCommandFile {
      reject("unknown", "invalidCommandFile")
    } catch {
      reject("unknown", "commandFileUnavailable")
    }
  }

  private func discover() {
    guard phase == .idle else { return reject("discover", "busy") }
    cameraNetwork = nil
    begin("discover", phase: .discovering)
    scan = Task {
      record("Discovery task entered the gateway")
      do {
        let updates = try await gateway.discover()
        record("Discovery gateway returned a stream")
        record("CoreBluetooth authorization: \(Self.authorizationLabel())")
        for try await cameras in updates {
          guard phase == .discovering else { return }
          let handles = Dictionary(uniqueKeysWithValues: candidates.map { ($0.value.id, $0.key) })
          for camera in cameras {
            let handle = handles[camera.id] ?? nextHandle
            if handles[camera.id] == nil { nextHandle += 1 }
            candidates[handle] = camera
          }
          publish()
        }
      } catch {
        guard phase == .discovering, !Task.isCancelled else { return }
        clearDiscovery()
        finish(Self.failureLabel(error), phase: .idle)
      }
    }
  }

  private static func authorizationLabel() -> String {
    switch CBManager.authorization {
    case .notDetermined: "notDetermined"
    case .restricted: "restricted"
    case .denied: "denied"
    case .allowedAlways: "allowedAlways"
    @unknown default: "unknown"
    }
  }

  private func select(_ handle: Int?) {
    guard phase == .discovering, let handle, let candidate = candidates[handle] else {
      return reject("select", "unknownCandidate")
    }
    guard candidate.advertisedModelHint != .xe3 else {
      return reject("select", "expectedXT5")
    }
    selectedHandle = handle
    lastCommand = "select"
    result = "selected"
    record("Selected candidate \(handle)")
    publish()
  }

  private func pair() {
    guard phase == .discovering, let selectedHandle, let candidate = candidates[selectedHandle] else {
      return reject("pair", "selectCandidateFirst")
    }
    verifiedPairingSession = nil
    begin("pair", phase: .pairing)
    operation = Task {
      defer { clearDiscovery() }
      do {
        let camera = try await gateway.pair(candidate)
        try Task.checkCancellation()
        guard camera.model == .xt5 else { throw WirelessFailure.peerMismatch }
        try await store.select(camera.id)
        try await completeLink(camera)
      } catch {
        await linkFailed(error, expectedPhase: .pairing)
      }
    }
  }

  private func reconnect() {
    guard phase == .idle else { return reject("reconnect", "busy") }
    cameraNetwork = nil
    begin("reconnect", phase: .reconnecting)
    operation = Task {
      do {
        try Task.checkCancellation()
        guard let selected = try await store.selected(),
          let camera = try await store.cameras().first(where: { $0.id == selected && $0.model == .xt5 })
        else {
          try Task.checkCancellation()
          finish("noSavedXT5", phase: .idle)
          operation = nil
          return
        }
        try Task.checkCancellation()
        savedModel = camera.model
        publish()
        try await gateway.reconnect(camera, allowPermissionPrompt: true)
        try await completeLink(camera)
      } catch {
        await linkFailed(error, expectedPhase: .reconnecting)
      }
    }
  }

  private func activateWiFi() {
    guard phase == .linked, let linkedCamera else { return reject("wifi", "connectCameraFirst") }
    cameraNetwork = nil
    begin("wifi", phase: .activatingWiFi)
    operation = Task {
      let label: String
      do {
        let selected = try await store.selected()
        let network = try await ProbeWiFiActivation.activate(
          camera: linkedCamera, selected: selected, gateway: gateway)
        guard phase == .activatingWiFi else { return }
        cameraNetwork = network
        label = "wifiReady"
      } catch {
        label = Self.failureLabel(error)
      }
      guard phase == .activatingWiFi else { return }
      operation = nil
      finish(label, phase: self.linkedCamera == nil ? .idle : .linked)
    }
  }

  private func completeLink(_ camera: SavedCamera) async throws {
    try Task.checkCancellation()
    let identity = try await gateway.identity(for: camera.id)
    try Task.checkCancellation()
    guard identity.model == .xt5 else { throw WirelessFailure.peerMismatch }
    linkedCamera = camera
    savedModel = camera.model
    operation = nil
    finish("ready", phase: .linked)
  }

  private func linkFailed(_ error: Error, expectedPhase: Phase) async {
    guard phase == expectedPhase else { return }
    await gateway.disconnect()
    guard phase == expectedPhase else { return }
    operation = nil
    finish(Self.failureLabel(error), phase: .idle)
  }

  private func disconnect(shutdown: Bool = false) {
    if phase == .stopped { return }
    if shutdown { shutdownRequested = true }
    if phase == .disconnecting {
      if shutdown { lastCommand = "quit" }
      return
    }
    cameraNetwork = nil
    begin(shutdown ? "quit" : "disconnect", phase: .disconnecting)
    clearDiscovery()
    let previous = operation
    previous?.cancel()
    operation = Task {
      await gateway.disconnect()
      await previous?.value
      linkedCamera = nil
      operation = nil
      if shutdownRequested {
        timer?.invalidate()
        finish("closed", phase: .stopped)
        NSApp.reply(toApplicationShouldTerminate: true)
      } else {
        finish("closed", phase: .idle)
      }
    }
  }

  private func clearDiscovery() {
    scan?.cancel()
    scan = nil
    candidates.removeAll()
    selectedHandle = nil
    publish()
  }

  private func begin(_ command: String, phase: Phase) {
    lastCommand = command
    finish("working", phase: phase)
  }

  private func finish(_ label: String, phase: Phase) {
    self.phase = phase
    result = label
    record("\(phase.rawValue): \(label)")
    publish()
  }

  private func reject(_ command: String, _ reason: String) {
    lastCommand = command
    result = reason
    record("\(command) rejected: \(reason)")
    publish()
  }

  private func publish() {
    var lines = [
      "phase=\(phase.rawValue)",
      "bluetooth=\(availability)",
      "last_command=\(lastCommand)",
      "result=\(result)",
      "saved_model=\(savedModel?.rawValue ?? "none")",
      "linked_model=\(linkedCamera?.model.rawValue ?? "none")",
      "selected=\(selectedHandle.map(String.init) ?? "none")",
      "wifi_ready=\(cameraNetwork != nil)",
      "wifi_security=\(cameraNetwork?.security == .wpaPersonal ? "wpaPersonal" : "none")",
      "wifi_model=\(cameraNetwork == nil ? "none" : WirelessCameraModel.xt5.rawValue)",
    ]
    for handle in candidates.keys.sorted() {
      let model = candidates[handle]?.advertisedModelHint?.rawValue ?? "unresolved"
      lines.append("candidate=\(handle) \(model)")
    }
    let status = lines.joined(separator: "\n") + "\n"
    guard previousStatus != status else { return }
    do {
      try directory.write(status, to: "status")
      previousStatus = status
      statusView.stringValue = status
    } catch {
      statusView.stringValue = "The private status file could not be written."
    }
  }

  private func record(_ message: String) {
    messages.append("\(Date().ISO8601Format()) \(message)")
    if messages.count > 256 { messages.removeFirst() }
    do {
      try directory.write(messages.joined(separator: "\n") + "\n", to: "events")
    } catch {
      statusView.stringValue = "The private event file could not be written."
    }
  }

  private func captureUnknownModel(_ model: String) {
    do {
      try directory.write(JSONEncoder().encode(model), to: "private-bluetooth-model.json")
    } catch {
      record("Private Device Information evidence could not be written")
    }
  }

  private static func failureLabel(_ error: Error) -> String {
    if error is CancellationError { return "cancelled" }
    if error is BluetoothPairingFailure { return "unresolvedModel" }
    if let failure = error as? WirelessFailure { return String(describing: failure) }
    return "unclassifiedError"
  }
}
