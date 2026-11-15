#if DEBUG
import Foundation
import FujiCameraCore
import SwiftUI
import UIKit

@MainActor
@Observable
final class ManualWiFiProbe {
  enum Selection {
    case saved(SavedCamera), discovered(DiscoveredCamera)

    var peripheralID: UUID {
      switch self {
      case .saved(let camera): camera.peripheralID
      case .discovered(let camera): camera.peripheralID
      }
    }
  }

  typealias SessionFactory = @Sendable (WirelessIdentity) async throws -> any WirelessTransferSession
  typealias StartLease = (@escaping @MainActor () -> Void) -> (() -> Void)?

  private let bluetooth: any BluetoothGateway
  private let loadSaved: () async throws -> [SavedCamera]
  private let password: (CameraCredentialReference) async throws -> String
  private let authorizeLaunch: (UUID, @escaping () -> Bool) throws -> Void
  private let makeSession: SessionFactory
  private let startLease: StartLease
  private let record: (ManualWiFiEvent) -> Void
  private var operation: Task<Void, Never>?
  private var scanning: Task<Void, Never>?
  private var scanID: UUID?
  private var leaseID: UUID?
  private var endLease: (() -> Void)?
  private var attempt: UUID?
  private var identity: WirelessIdentity?
  private var secret: String?
  private var revealing = false
  private var foreground = false

  private(set) var saved: [SavedCamera] = []
  private(set) var discovered: [DiscoveredCamera] = []
  private(set) var status = "Select a saved camera or start Bluetooth discovery."
  private(set) var handoff: CameraNetwork?
  private(set) var userConfirmed = false

  var visiblePassword: String? { foreground && revealing ? secret : nil }
  var canSelect: Bool { foreground && operation == nil }
  var canScan: Bool { canSelect && handoff == nil && scanning == nil }
  var canConfirm: Bool { canSelect && handoff != nil && !userConfirmed }
  var canIdentify: Bool { canSelect && handoff != nil && userConfirmed }
  var canCancel: Bool { attempt != nil || scanning != nil }

  init(
    bluetooth: any BluetoothGateway, loadSaved: @escaping () async throws -> [SavedCamera],
    password: @escaping (CameraCredentialReference) async throws -> String,
    authorizeLaunch: @escaping (UUID, @escaping () -> Bool) throws -> Void,
    makeSession: @escaping SessionFactory, startLease: @escaping StartLease,
    record: @escaping (ManualWiFiEvent) -> Void
  ) {
    self.bluetooth = bluetooth
    self.loadSaved = loadSaved
    self.password = password
    self.authorizeLaunch = authorizeLaunch
    self.makeSession = makeSession
    self.startLease = startLease
    self.record = record
  }

  func observe() async {
    let events = await bluetooth.events()
    do { saved = try await loadSaved().filter { $0.model == .xt5 } }
    catch { status = "Saved cameras are unavailable. Try Bluetooth discovery." }
    for await event in events { bluetoothEvent(event) }
  }

  func scan() {
    guard canScan else { return }
    let id = UUID()
    scanID = id
    discovered = []
    update(.discovering, "On the camera, open Bluetooth pairing. Select it when it appears.")
    scanning = Task {
      defer {
        if scanID == id {
          scanID = nil
          scanning = nil
        }
      }
      do {
        for try await cameras in try await bluetooth.discover() {
          guard scanID == id, !Task.isCancelled else { return }
          discovered = cameras.filter { $0.advertisedModelHint != .xe3 }
        }
      } catch {
        if scanID == id, !Task.isCancelled {
          update(.bluetoothFailed, Self.failureMessage(error, fallback: "Discovery stopped. Check Bluetooth and try again."))
        }
      }
    }
  }

  func connect(_ selection: Selection) {
    guard canSelect else { return }
    let replace = attempt != nil
    invalidateHandoff()
    let id = UUID()
    attempt = id
    update(.authenticating, "Connecting to the selected camera over Bluetooth…")
    operation = Task {
      if replace { await bluetooth.disconnect() }
      do {
        try check(id)
        let camera: SavedCamera
        switch selection {
        case .saved(let selected):
          camera = selected
          try await bluetooth.reconnect(selected, allowPermissionPrompt: true)
        case .discovered(let selected):
          camera = try await bluetooth.pair(selected)
          try check(id)
          saved = try await loadSaved().filter { $0.model == .xt5 }
        }
        try check(id)
        stopScan()
        let observed = try await bluetooth.identity(for: camera.id)
        try check(id)
        guard observed.cameraID == camera.id, camera.model == .xt5, observed.model == .xt5 else {
          throw WirelessFailure.peerMismatch
        }
        let firmware = ManualWiFiEvent.firmware(observed.firmware)
        guard firmware != "unavailable" else { throw WirelessFailure.unsupportedFirmware }

        identity = observed
        update(.activating, "Starting the camera Wi-Fi network…", firmware: firmware)
        let selectionIsCurrent = currentSelectionCheck(id)
        try authorizeLaunch(selection.peripheralID, selectionIsCurrent)
        let network = try await bluetooth.activateWiFi(for: camera.id)
        try check(id)
        guard network.credential.cameraID == camera.id else { throw WirelessFailure.peerMismatch }
        let activationPassword = try await password(network.credential)
        guard try await bluetooth.identity(for: camera.id) == observed else { throw WirelessFailure.peerMismatch }
        try check(id)
        handoff = network
        secret = activationPassword
        operation = nil
        update(.ready, "Camera Wi-Fi is ready. Join it in Settings, then return here.", firmware: firmware)
      } catch {
        guard attempt == id else { return }
        let phase: ManualWiFiEvent.Phase = identity == nil ? .bluetoothFailed : .activationFailed
        await finish(phase, Self.failureMessage(error, fallback: "The camera connection stopped. Select it again to retry."))
      }
    }
  }

  func revealPassword() {
    guard foreground, handoff != nil else { return }
    revealing.toggle()
  }

  func confirmJoined() {
    guard canConfirm else { return }
    revealing = false
    userConfirmed = true
    update(.userConfirmed, "Network confirmed by you. Run the camera identity test.")
  }

  func identify() {
    guard canIdentify, let id = attempt, let identity, let handoff else { return }
    revealing = false
    update(.identifying, "Reading the camera model and firmware over Wi-Fi…")
    operation = Task {
      do {
        try check(id)
        guard try await bluetooth.identity(for: identity.cameraID) == identity else { throw WirelessFailure.peerMismatch }
        try check(id)
        let observed = try await Self.readIdentity(identity, makeSession: makeSession)
        try check(id)
        guard self.handoff == handoff, userConfirmed,
          try await bluetooth.identity(for: identity.cameraID) == identity,
          observed.model == .xt5 else { throw WirelessFailure.peerMismatch }
        try check(id)
        let firmware = ManualWiFiEvent.firmware(observed.firmware)
        guard firmware != "unavailable" else { throw WirelessFailure.unsupportedFirmware }
        await finish(.identified, "X-T5 identified. Firmware \(firmware).", firmware: firmware)
      } catch {
        guard attempt == id else { return }
        await finish(.identityFailed, Self.failureMessage(error, fallback: "Identity test failed. Check the camera network in Settings and retry."))
      }
    }
  }

  func cancel() {
    guard canCancel else { return }
    retire(.cancelled, "Cancelled. Select a camera to retry.")
  }

  func sceneChanged(_ phase: ScenePhase) {
    foreground = phase == .active
    if !foreground { revealing = false }
    switch phase {
    case .active:
      releaseLease()
    case .inactive:
      break
    case .background:
      guard canCancel else { return }
      guard handoff != nil, operation == nil else {
        retire(.leftDuringOperation, "The test stopped in the background. Select a camera to retry.")
        return
      }
      guard leaseID == nil else { return }
      let id = UUID()
      leaseID = id
      endLease = startLease { [weak self] in
        guard let self, self.leaseID == id else { return }
        self.retire(.leaseExpired, "The Settings handoff expired. Select the camera to retry.")
      }
      if endLease == nil { retire(.leaseExpired, "The Settings handoff expired. Select the camera to retry.") }
    @unknown default:
      if canCancel { retire(.leftDuringOperation, "The test stopped. Select a camera to retry.") }
    }
  }

  func bluetoothEvent(_ event: BluetoothGatewayEvent) {
    guard attempt != nil else { return }
    switch event {
    case .disconnected(let id, _) where identity?.cameraID == id:
      retire(.bluetoothLost, "Bluetooth connection lost. Check the camera and select it to retry.")
    case .availability(.poweredOff), .availability(.unsupported), .availability(.unauthorized):
      retire(.bluetoothLost, "Bluetooth connection lost. Check the camera and select it to retry.")
    default: break
    }
  }

  func waitForOperation() async { await operation?.value }

  private func currentSelectionCheck(_ id: UUID) -> () -> Bool {
    { [weak self] in self?.attempt == id }
  }

  private func check(_ id: UUID) throws {
    try Task.checkCancellation()
    guard attempt == id else { throw CancellationError() }
  }

  private func stopScan() {
    scanID = nil
    scanning?.cancel()
    scanning = nil
    discovered = []
  }

  private func releaseLease() {
    leaseID = nil
    let end = endLease
    endLease = nil
    end?()
  }

  private func invalidateHandoff() {
    releaseLease()
    attempt = nil
    identity = nil
    handoff = nil
    secret = nil
    revealing = false
    userConfirmed = false
  }

  private func retire(_ phase: ManualWiFiEvent.Phase, _ message: String) {
    let pending = operation
    pending?.cancel()
    invalidateHandoff()
    stopScan()
    update(phase, message)
    operation = Task {
      await bluetooth.disconnect()
      await pending?.value
      operation = nil
    }
  }

  private func finish(_ phase: ManualWiFiEvent.Phase, _ message: String, firmware: String? = nil) async {
    invalidateHandoff()
    stopScan()
    await bluetooth.disconnect()
    update(phase, message, firmware: firmware)
    operation = nil
  }

  private func update(_ phase: ManualWiFiEvent.Phase, _ message: String, firmware: String? = nil) {
    status = message
    record(ManualWiFiEvent(phase: phase, observedFirmware: firmware))
  }

  private static func failureMessage(_ error: Error, fallback: String) -> String {
    guard let failure = error as? WirelessFailure else { return fallback }
    switch failure {
    case .permissionDenied(.bluetooth): return "Allow Bluetooth for Fuji Manual WiFi in Settings, then retry."
    case .permissionDenied(.localNetwork): return "Allow Local Network access for Fuji Manual WiFi in Settings, then retry."
    case .unsupportedFirmware: return "The camera firmware could not be admitted. The X-T5 requires firmware 4.30 or later."
    case .peerMismatch: return "The selected X-T5 could not be verified. Check the camera and retry."
    case .timeout(.wifiReadiness): return "Camera Wi-Fi did not become ready. Check the camera and retry."
    default: return fallback
    }
  }

  private static func readIdentity(
    _ expected: WirelessIdentity, makeSession: @escaping SessionFactory
  ) async throws -> WirelessIdentity {
    try await withThrowingTaskGroup(of: WirelessIdentity.self) { group in
      group.addTask {
        let session = try await makeSession(expected)
        let result: Result<WirelessIdentity, Error>
        do {
          try Task.checkCancellation()
          result = .success(try await session.open())
        } catch {
          result = .failure(error)
        }
        try await Task { try await session.close() }.value
        return try result.get()
      }
      group.addTask {
        try await Task.sleep(for: .seconds(20))
        throw WirelessFailure.timeout(.transactionInactivity)
      }
      defer { group.cancelAll() }
      guard let identity = try await group.next() else { throw WirelessFailure.connectionLost }
      return identity
    }
  }
}

struct ManualWiFiEvent: Encodable {
  enum Phase: String, Encodable {
    case discovering, authenticating, bluetoothFailed, activating, activationFailed
    case ready, userConfirmed, identifying, identified, identityFailed
    case cancelled, leftDuringOperation, leaseExpired, bluetoothLost
  }

  let timestamp = Date()
  let phase: Phase
  let observedFirmware: String?

  init(phase: Phase, observedFirmware: String?) {
    self.phase = phase
    self.observedFirmware = observedFirmware.map(Self.firmware)
  }

  static func firmware(_ raw: String?) -> String {
    let label = ProbeFirmwareObservation.label(raw)
    return WirelessSupportPolicy().assess(model: "X-T5", firmware: label) == .supported(.xt5)
      ? label : "unavailable"
  }
}

@MainActor
private final class ManualWiFiReport {
  private var events: [ManualWiFiEvent] = []

  init() { write() }

  func append(_ event: ManualWiFiEvent) {
    events.append(event)
    write()
  }

  private func write() {
    do {
      let documents = try FileManager.default.url(
        for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(events).write(
        to: documents.appending(path: "ManualWiFiProbe.json"), options: [.atomic, .completeFileProtection])
    } catch {
      // Diagnostic storage failure must not disclose the underlying error or camera data.
    }
  }
}

extension ManualWiFiProbe {
  static func live() -> ManualWiFiProbe {
    let suite = "com.lun3x.FujiStudio.wireless-protocol-probe"
    let defaults = UserDefaults(suiteName: suite)!
    let store = KeychainCameraStore(defaults: defaults, service: suite)
    let clientID = defaults.string(forKey: "clientID").flatMap(UUID.init(uuidString:)) ?? UUID()
    defaults.set(clientID.uuidString, forKey: "clientID")
    let guid = withUnsafeBytes(of: clientID.uuid) { Data($0) }
    let driver = ManualWiFiBluetoothDriver()
    let report = ManualWiFiReport()
    return ManualWiFiProbe(
      bluetooth: NativeBluetoothGateway(store: store, driver: driver),
      loadSaved: { try await store.cameras() },
      password: { try await store.password(for: $0) },
      authorizeLaunch: { try driver.beginImageViewing(peripheralID: $0, selectionIsCurrent: $1) },
      makeSession: { identity in
        let channel = try await NetworkByteChannel.connect(to: .cameraHosted(mode: .xApp))
        return XAppTransferAdapter.makeSession(
          transport: WirelessPTPTransport(channel: channel), expectedIdentity: identity, clientGUID: guid)
      },
      startLease: { expire in
        let app = UIApplication.shared
        let background = app.beginBackgroundTask(withName: "Camera Wi-Fi Settings handoff") {
          MainActor.assumeIsolated { expire() }
        }
        guard background != .invalid else { return nil }
        let timer = Task {
          do { try await Task.sleep(for: .seconds(25)) } catch { return }
          expire()
        }
        return {
          timer.cancel()
          app.endBackgroundTask(background)
        }
      },
      record: { report.append($0) })
  }
}
#endif
