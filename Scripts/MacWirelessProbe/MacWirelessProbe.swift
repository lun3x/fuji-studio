import AppKit
import CoreBluetooth
import CoreLocation
import Darwin
import Foundation
import FujiCameraCore

@main
struct MacWirelessProbe {
  @MainActor
  static func main() {
    umask(0o077)
    let arguments = CommandLine.arguments
    if arguments.count == 2, ["--wifi-worker", "--wifi-reassociate"].contains(arguments[1]) {
      guard NSRunningApplication(processIdentifier: getppid())?.bundleURL?.resolvingSymlinksInPath()
        == Bundle.main.bundleURL.resolvingSymlinksInPath()
      else { exit(2) }
      exit(arguments[1] == "--wifi-worker" ? ProbeMacWiFiWorker.main() : ProbeMacWiFiWorker.reassociate())
    }
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
    case idle, discovering, pairing, observingSaved, reconnecting, linked, activatingWiFi, disconnecting, stopped
    case checkingWiFi, rehearsingRestore, probingPTP
  }

  private enum ReconnectMode: String {
    case standard = "reconnect"
    case registration = "reconnect-registration"
  }

  private let directory: RunDirectory
  private let probeDefaults: UserDefaults
  private let store: KeychainCameraStore
  private let registrationDriver: ProbeRegistrationBluetoothDriver
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
  private var bleFirmware = "unavailable"
  private var savedModel: WirelessCameraModel?
  private var cameraNetwork: ProbeReadyCameraNetwork?
  private var ptpReport = ProbePTPIdentityReport()
  private var restorationRehearsal = ProbeWiFiOnlyRehearsal()
  private let association = ProbeMacWiFiAssociation()
  private lazy var location = CLLocationManager()
  private var savedAdvertisement = SavedAdvertisementObservation()
  private var secureStatus = ProbeSecureStatusComparison()
  private var messages: [(timestamp: Date, line: String)] = []
  private var previousStatus: String?

  init(directory: RunDirectory) {
    self.directory = directory
    let service = "com.lun3x.FujiStudio.MacWirelessProbe.camera"
    let keychain = ProbeKeychain()
    probeDefaults = UserDefaults(suiteName: service)!
    store = KeychainCameraStore(
      defaults: probeDefaults, service: service, keychain: keychain)
    let native = CoreBluetoothDriver()
    let driver = ProbeRegistrationBluetoothDriver(native: native)
    registrationDriver = driver
    gateway = NativeBluetoothGateway(store: store, driver: registrationDriver)
    super.init()

    keychain.observe = { [weak self] event in self?.record(event) }
    native.observePairing = { [weak self] event in self?.record(event) }
    native.observeUnrecognizedModel = { [weak self] model in self?.captureUnknownModel(model) }
    driver.observeAcknowledgement = { [weak self] in
      self?.record("registration_ack_used=true")
      self?.publish()
    }
    driver.flushRegistrationNotifications = { [weak self] entries in self?.recordRegistrationNotifications(entries) }

    // Preserve the production link and profile. Only first pairing on this
    // test rig has a stricter admission rule: DIS must report X-T5.
    let forward = driver.eventHandler
    driver.eventHandler = { [weak self] event in
      guard let self else { return }
      var statusObservation: ProbeSecureStatusComparison.Observation?
      switch event {
      case .availability(let availability):
        self.record("Driver reported Bluetooth \(availability)")
      case .peerModel(let session, let value)
        where self.phase == .pairing || self.phase == .reconnecting:
        if value.flatMap(WirelessCameraModel.init(bluetoothModelNumber:)) == .xt5 {
          self.secureStatus.verifyXT5(session: session)
          if self.phase == .pairing { self.verifiedPairingSession = session }
        }
      case .protocolEvent(let session, .services) where self.phase == .pairing:
        guard self.verifiedPairingSession == session else {
          self.record("Pairing requires a verified X-T5 Device Information model")
          forward?(.linkFailed(session, .unsupportedProtocol))
          return
        }
      case .protocolEvent(let session, let protocolEvent)
        where self.phase == .pairing || self.phase == .reconnecting:
        if self.secureStatus.receive(protocolEvent, session: session) {
          statusObservation = self.secureStatus.observation
        }
      default:
        break
      }
      forward?(event)
      if let statusObservation {
        self.record("Secure status: " + statusObservation.statusLines.joined(separator: " "))
        self.publish()
      }
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let frame = NSRect(x: 0, y: 0, width: 460, height: 360)
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
          guard linkedCamera?.id == id,
            phase == .linked || phase == .activatingWiFi || phase == .checkingWiFi || phase == .probingPTP
          else {
            continue
          }
          linkedCamera = nil
          let label = Self.failureLabel(failure)
          if phase == .probingPTP {
            operation?.cancel()
            record("BLE disconnected during PTP identity test: \(label)")
            continue
          }
          if phase == .checkingWiFi {
            cameraNetwork = nil
            continue
          }
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
      case ("observe-saved", 1): observeSavedAdvertisement()
      case ("reconnect", 1): reconnect()
      case ("reconnect-registration", 1): reconnect(.registration)
      case ("wifi", 1): activateWiFi()
      case ("wifi-image-viewing", 1): activateWiFi(imageViewing: true)
      case ("wifi-preflight", 1): preflightWiFi()
      case ("wifi-only-preflight", 1): preflightWiFi(wifiOnly: true)
      case ("wifi-restore-rehearsal", 1): rehearseWiFiRestore()
      case ("ptp-identity", 1): probePTPIdentity()
      case ("ptp-identity-wifi-only", 1): probePTPIdentity(wifiOnly: true)
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
    savedAdvertisement = SavedAdvertisementObservation()
    ptpReport = ProbePTPIdentityReport()
    registrationDriver.resetObservation()
    registrationDriver.beginRegistrationObservation(peripheralID: candidate.peripheralID)
    secureStatus.begin(.pairing, peripheralID: candidate.peripheralID)
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

  private func reconnect(_ mode: ReconnectMode = .standard) {
    let command = mode.rawValue
    guard phase == .idle else { return reject(command, "busy") }
    cameraNetwork = nil
    ptpReport = ProbePTPIdentityReport()
    registrationDriver.resetObservation()
    secureStatus.resetObservation()
    let ticket = secureStatus.takeRegistrationTicket()
    if mode == .registration, ticket == nil { return reject(command, "registrationEvidenceRequired") }
    begin(command, phase: .reconnecting)
    operation = Task { [self] in
      do {
        try Task.checkCancellation()
        guard let camera = try await selectedXT5() else {
          try Task.checkCancellation()
          secureStatus.clearRegistrationTicket()
          finish("noSavedXT5", phase: .idle)
          operation = nil
          return
        }
        try Task.checkCancellation()
        let selectionIsCurrent = { [weak self] in
          self?.selectionMatches(camera.id, phase: .reconnecting) == true
        }
        if mode == .registration {
          guard let ticket, ticket.matches(peripheralID: camera.peripheralID, cameraID: camera.id)
          else {
            operation = nil
            finish("registrationEvidenceRequired", phase: .idle)
            return
          }
          guard registrationDriver.beginExperiment(ticket, selectionIsCurrent: selectionIsCurrent) else {
            throw WirelessFailure.peerMismatch
          }
        }
        secureStatus.begin(mode == .registration ? .registrationReconnect : .reconnect,
          peripheralID: camera.peripheralID, cameraID: camera.id)
        registrationDriver.beginRegistrationObservation(peripheralID: camera.peripheralID)
        savedModel = camera.model
        publish()
        try await gateway.reconnect(camera, allowPermissionPrompt: true)
        try await completeLink(camera)
      } catch {
        await linkFailed(error, expectedPhase: .reconnecting, allowsRegistrationTicket: mode == .standard)
      }
    }
  }

  private func selectedXT5() async throws -> SavedCamera? {
    guard let selected = try await store.selected() else { return nil }
    try Task.checkCancellation()
    return try await store.cameras().first { $0.id == selected && $0.model == .xt5 }
  }

  private func selectionMatches(_ cameraID: WirelessCameraID, phase: Phase) -> Bool {
    guard self.phase == phase else { return false }
    let selected = probeDefaults.string(forKey: "wireless.selectedCameraID")
    return selected.flatMap(UUID.init(uuidString:)) == cameraID.rawValue
  }

  private func observeSavedAdvertisement() {
    guard phase == .idle else { return reject("observe-saved", "busy") }
    savedAdvertisement = SavedAdvertisementObservation()
    begin("observe-saved", phase: .observingSaved)
    operation = Task {
      let label: String
      do {
        try Task.checkCancellation()
        if let camera = try await selectedXT5() {
          try Task.checkCancellation()
          savedModel = camera.model
          publish()
          let observer = ProbeSavedAdvertisementObserver(savedPeripheralID: camera.peripheralID)
          let observation = try await observer.observe()
          try Task.checkCancellation()
          guard phase == .observingSaved else { return }
          savedAdvertisement = observation
          label = observation.ready ? "savedAdvertReady" : "savedAdvertTimedOut"
        } else {
          label = "noSavedXT5"
        }
      } catch {
        label = Self.failureLabel(error)
      }
      guard phase == .observingSaved else { return }
      operation = nil
      finish(label, phase: .idle)
    }
  }

  private func activateWiFi(imageViewing: Bool = false) {
    let command = imageViewing ? "wifi-image-viewing" : "wifi"
    guard phase == .linked, let linkedCamera else { return reject(command, "connectCameraFirst") }
    cameraNetwork = nil
    ptpReport = ProbePTPIdentityReport()
    registrationDriver.resetImageViewingObservation()
    begin(command, phase: .activatingWiFi)
    operation = Task { [self] in
      defer { registrationDriver.endImageViewing() }
      let label: String
      do {
        let selected = try await store.selected()
        let network = try await ProbeWiFiActivation.activate(
          camera: linkedCamera, selected: selected, gateway: gateway, launch: imageViewing ? .imageViewing : .standard
        ) {
          guard imageViewing else { return }
          guard registrationDriver.beginImageViewing(peripheralID: linkedCamera.peripheralID,
            selectionIsCurrent: { [weak self] in
              self?.linkedCamera?.id == linkedCamera.id
                && self?.selectionMatches(linkedCamera.id, phase: .activatingWiFi) == true
            })
          else { throw WirelessFailure.peerMismatch }
        }
        guard phase == .activatingWiFi else { return }
        if imageViewing, !registrationDriver.imageViewLaunchUsed { throw WirelessFailure.unsupportedProtocol }
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

  private var wifiLocationAllowed: Bool {
    switch location.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse: true
    default: false
    }
  }

  private func preflightWiFi(wifiOnly: Bool = false) {
    let command = wifiOnly ? "wifi-only-preflight" : "wifi-preflight"
    guard phase == .idle || phase == .linked else { return reject(command, "busy") }
    guard wifiLocationAllowed else {
      if location.authorizationStatus == .notDetermined {
        NSApp.activate()
        location.requestWhenInUseAuthorization()
      }
      return reject(command, "locationPermissionRequired")
    }
    begin(command, phase: .checkingWiFi)
    operation = Task {
      let label: String
      do {
        if wifiOnly {
          _ = try await ProbeWiFiOnlyRecovery.preflight(association)
        } else {
          try await ProbePTPIdentity.preflight(association: association, wiredRoute: ProbeWiredRoute.detect)
        }
        label = "wifiPreflightReady"
      } catch {
        label = ProbePTPIdentity.failureLabel(error)
      }
      guard phase == .checkingWiFi else { return }
      operation = nil
      finish(label, phase: linkedCamera == nil ? .idle : .linked)
    }
  }

  private func rehearseWiFiRestore() {
    let command = "wifi-restore-rehearsal"
    guard phase == .idle else { return reject(command, "disconnectCameraFirst") }
    guard wifiLocationAllowed else { return reject(command, "locationPermissionRequired") }
    restorationRehearsal = ProbeWiFiOnlyRehearsal()
    begin(command, phase: .rehearsingRestore)
    operation = Task {
      restorationRehearsal = await ProbeWiFiOnlyRecovery.rehearse(association)
      record("Wi-Fi restoration rehearsal outcome=\(restorationRehearsal.outcome)")
      guard phase == .rehearsingRestore else { publish(); return }
      operation = nil
      finish(restorationRehearsal.outcome, phase: .idle)
    }
  }

  private func probePTPIdentity(wifiOnly: Bool = false) {
    let command = wifiOnly ? "ptp-identity-wifi-only" : "ptp-identity"
    guard phase == .linked, let camera = linkedCamera, let receipt = cameraNetwork,
      let session = registrationDriver.verifiedReadySession(for: camera.peripheralID),
      receipt.identity.cameraID == camera.id
    else { return reject(command, "connectCameraAndActivateWiFi") }
    guard wifiLocationAllowed else { return reject(command, "locationPermissionRequired") }
    let restoreReceipt: ProbeWiFiOnlyReceipt?
    if wifiOnly {
      guard let recent = restorationRehearsal.takeReceipt() else {
        return reject(command, "restoreRehearsalRequired")
      }
      restoreReceipt = recent
    } else {
      restoreReceipt = nil
    }
    let guid = ptpClientGUID()
    cameraNetwork = nil
    ptpReport = ProbePTPIdentityReport(launch: receipt.launch)
    begin(command, phase: .probingPTP)
    operation = Task {
      let report: ProbePTPIdentityReport
      do {
        try Task.checkCancellation()
        let currentIdentity = try await gateway.identity(for: camera.id)
        report = await ProbePTPIdentity.run(
          receipt, currentIdentity: currentIdentity, credentials: store, association: association,
          wiredRoute: ProbeWiredRoute.detect,
          wifiOnly: restoreReceipt.map { (receipt: $0, association: association) },
          isCurrent: { [self] in
            linkedCamera?.id == camera.id && selectionMatches(camera.id, phase: .probingPTP)
              && registrationDriver.verifiedReadySession(for: camera.peripheralID) == session
          },
          makeSession: { identity in
            let channel = try await NetworkByteChannel.connect(to: .cameraHosted(mode: .xApp))
            let transport = WirelessPTPTransport(channel: channel, inactivityTimeout: .seconds(5))
            return XAppTransferAdapter.makeSession(transport: transport, expectedIdentity: identity, clientGUID: guid)
          })
      } catch {
        var failure = ProbePTPIdentityReport(launch: receipt.launch)
        failure.outcome = ProbePTPIdentity.failureLabel(error)
        report = failure
      }
      ptpReport = report
      record("PTP identity outcome=\(report.outcome) wifi_restore=\(report.restoration.rawValue)")
      guard phase == .probingPTP else { publish(); return }
      operation = nil
      let label = report.restoration == .unverified ? "restoreUnverified" : report.outcome
      finish(label, phase: linkedCamera == nil ? .idle : .linked)
    }
  }

  private func ptpClientGUID() -> Data {
    let key = "wireless.ptpClientID"
    let client = probeDefaults.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
    probeDefaults.set(client.uuidString, forKey: key)
    return withUnsafeBytes(of: client.uuid) { Data($0) }
  }

  private func completeLink(_ camera: SavedCamera) async throws {
    try Task.checkCancellation()
    let identity = try await gateway.identity(for: camera.id)
    try Task.checkCancellation()
    guard identity.model == .xt5 else { throw WirelessFailure.peerMismatch }
    bleFirmware = ProbeFirmwareObservation.label(identity.firmware)
    if phase == .pairing {
      if secureStatus.commitPairing(peripheralID: camera.peripheralID, cameraID: camera.id) {
        record("Secure status baseline committed: true")
      }
    } else {
      secureStatus.endAttempt()
    }
    registrationDriver.endExperiment()
    linkedCamera = camera
    savedModel = camera.model
    operation = nil
    registrationDriver.markRegistrationObservationReady(peripheralID: camera.peripheralID)
    finish("ready", phase: .linked)
  }

  private func linkFailed(
    _ error: Error, expectedPhase: Phase, allowsRegistrationTicket: Bool = false
  ) async {
    guard phase == expectedPhase else { return }
    registrationDriver.endRegistrationObservation()
    if expectedPhase == .pairing { secureStatus.endAttempt() }
    await gateway.disconnect()
    guard phase == expectedPhase else { return }
    if allowsRegistrationTicket, !Task.isCancelled, !(error is CancellationError) {
      secureStatus.finishFailedReconnect()
    } else {
      secureStatus.endAttempt()
    }
    registrationDriver.endExperiment()
    operation = nil
    finish(Self.failureLabel(error), phase: .idle)
  }

  private func disconnect(shutdown: Bool = false) {
    if phase == .stopped { return }
    if shutdown {
      shutdownRequested = true
      secureStatus = ProbeSecureStatusComparison()
    }
    if phase == .disconnecting {
      if shutdown { lastCommand = "quit" }
      return
    }
    secureStatus.endAttempt()
    registrationDriver.endRegistrationObservation()
    cameraNetwork = nil
    let restoringWiFi = phase == .probingPTP || phase == .rehearsingRestore
    begin(shutdown ? "quit" : "disconnect", phase: .disconnecting)
    clearDiscovery()
    let previous = operation
    previous?.cancel()
    operation = Task {
      if restoringWiFi { await previous?.value }
      await gateway.disconnect()
      if !restoringWiFi { await previous?.value }
      registrationDriver.endExperiment()
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
      "ble_firmware=\(linkedCamera == nil ? "unavailable" : bleFirmware)",
      "selected=\(selectedHandle.map(String.init) ?? "none")",
      "wifi_ready=\(cameraNetwork != nil)",
      "wifi_security=\(cameraNetwork?.network.security == .wpaPersonal ? "wpaPersonal" : "none")",
      "wifi_model=\(cameraNetwork == nil ? "none" : WirelessCameraModel.xt5.rawValue)",
      "ptp_launch=\(ptpReport.launch?.rawValue ?? "none")",
      "ptp_camera_associated=\(ptpReport.associated)",
      "ptp_identity_verified=\(ptpReport.verified)",
      "ptp_firmware=\(ptpReport.firmware)",
      "wifi_restore=\(ptpReport.restoration.rawValue)",
      "wifi_rehearsal_gap_observed=\(restorationRehearsal.gapObserved)",
      "wifi_rehearsal_exact_restore_completed=\(restorationRehearsal.exactRestoreCommandCompleted)",
      "wifi_rehearsal_restoration_verified=\(restorationRehearsal.restorationVerified)",
      "saved_advert_identity=\(savedAdvertisement.matchingIdentity)",
      "saved_advert_service=\(savedAdvertisement.matchingService)",
      "saved_advert_shape=\(savedAdvertisement.matchingShape)",
      "saved_advert_ready=\(savedAdvertisement.ready)",
      "registration_ack_used=\(registrationDriver.acknowledgementUsed)",
      "image_view_launch_used=\(registrationDriver.imageViewLaunchUsed)",
    ]
    lines.append(contentsOf: secureStatus.observation.statusLines)
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
    let timestamp = Date()
    messages.append((timestamp, "\(timestamp.ISO8601Format()) \(message)"))
    writeMessages()
  }

  private func recordRegistrationNotifications(_ entries: [ProbeRegistrationNotificationEntry]) {
    messages.append(contentsOf: entries.map {
      ($0.timestamp, "\($0.timestamp.ISO8601Format()) \($0.message)")
    })
    messages.sort { $0.timestamp < $1.timestamp }
    writeMessages()
  }

  private func writeMessages() {
    if messages.count > 256 { messages.removeFirst(messages.count - 256) }
    do {
      try directory.write(messages.map { $0.line }.joined(separator: "\n") + "\n", to: "events")
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
