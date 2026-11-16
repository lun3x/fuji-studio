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

    var linkMode: ManualWiFiEvent.LinkMode {
      switch self {
      case .saved: .reconnect
      case .discovered: .pair
      }
    }

    var peripheralID: UUID {
      switch self {
      case .saved(let camera): camera.peripheralID
      case .discovered(let camera): camera.peripheralID
      }
    }
  }

  private struct LinkedCamera {
    let identity: WirelessIdentity
    let peripheralID: UUID
    let mode: ManualWiFiEvent.LinkMode
  }

  typealias SessionFactory = @Sendable (WirelessIdentity, WirelessIdentityTrace.Observer?) async throws -> any WirelessTransferSession
  enum LeaseExpiration { case watchdog, hardDeadline }

  typealias StartLease = (@escaping @MainActor (LeaseExpiration) -> Void) -> (() -> Void)?

  private let bluetooth: any BluetoothGateway
  private let loadSaved: () async throws -> [SavedCamera]
  private let findPaired: ([SavedCamera]) async throws -> ManualPairedCameraMatches
  private let password: (CameraCredentialReference) async throws -> String
  private let authorizeLaunch: (UUID, @escaping () -> Bool) throws -> Void
  private let makeSession: SessionFactory
  private let startLease: StartLease
  private let record: (ManualWiFiEvent) -> Void
  private let identityTrace: ManualWiFiIdentityTrace?
  private var operation: Task<Void, Never>?
  private var scanning: Task<Void, Never>?
  private var scanID: UUID?
  private var leaseID: UUID?
  private var endLease: (() -> Void)?
  private var attempt: UUID?
  private var linkedCamera: LinkedCamera?
  private var identity: WirelessIdentity? { linkedCamera?.identity }
  private var secret: String?
  private var revealing = false
  private var foreground = false

  private(set) var saved: [SavedCamera] = []
  private(set) var pairedNearby: [SavedCamera] = []
  private(set) var discovered: [DiscoveredCamera] = []
  private(set) var status = "Find your paired X-T5 or pair a new camera."
  private(set) var handoff: CameraNetwork?
  private(set) var registrationConfirmed = false
  private(set) var userConfirmed = false

  var visiblePassword: String? { foreground && revealing ? secret : nil }
  var canSelect: Bool { foreground && operation == nil }
  var canScan: Bool { canSelect && linkedCamera == nil && scanning == nil }
  var canReconnect: Bool { canSelect && scanning == nil }
  var registrationMode: ManualWiFiEvent.LinkMode? { handoff == nil ? linkedCamera?.mode : nil }
  var linkedRecordID: WirelessCameraID? { identity?.cameraID }
  var canConfirmRegistration: Bool { canSelect && registrationMode != nil && !registrationConfirmed }
  var canStartWiFi: Bool { canSelect && registrationMode != nil && registrationConfirmed }
  var canConfirm: Bool { canSelect && handoff != nil && !userConfirmed }
  var canIdentify: Bool { canSelect && handoff != nil && userConfirmed }
  var canCancel: Bool { attempt != nil || scanning != nil }

  init(
    bluetooth: any BluetoothGateway, loadSaved: @escaping () async throws -> [SavedCamera],
    findPaired: @escaping ([SavedCamera]) async throws -> ManualPairedCameraMatches,
    password: @escaping (CameraCredentialReference) async throws -> String,
    authorizeLaunch: @escaping (UUID, @escaping () -> Bool) throws -> Void,
    makeSession: @escaping SessionFactory, startLease: @escaping StartLease,
    record: @escaping (ManualWiFiEvent) -> Void, identityTrace: ManualWiFiIdentityTrace? = nil
  ) {
    self.bluetooth = bluetooth
    self.loadSaved = loadSaved
    self.findPaired = findPaired
    self.password = password
    self.authorizeLaunch = authorizeLaunch
    self.makeSession = makeSession
    self.startLease = startLease
    self.record = record
    self.identityTrace = identityTrace
  }

  func observe() async {
    let events = await bluetooth.events()
    do { saved = try await loadSaved().filter { $0.model == .xt5 } }
    catch { status = "Saved cameras are unavailable. Unlock the phone and try again." }
    for await event in events { bluetoothEvent(event) }
  }

  func findPairedCamera() {
    guard canScan else { return }
    let id = UUID()
    scanID = id
    pairedNearby = []
    discovered = []
    update(.findingPaired, "Looking for the paired X-T5. Keep it awake in normal shooting mode.")
    scanning = Task {
      defer { endScan(id) }
      do {
        let records = try await loadSaved()
        guard scanID == id, !Task.isCancelled else { return }
        saved = records.filter { $0.model == .xt5 }
        let matches = try await findPaired(records)
        guard scanID == id, !Task.isCancelled else { return }
        pairedNearby = matches.cameras
        if matches.ambiguous {
          update(.pairedAmbiguous, "A nearby camera matches more than one saved record. Those records cannot be selected from this search.")
        } else if pairedNearby.isEmpty {
          update(.pairedNotFound, "No paired X-T5 found. Wake the camera, check that Bluetooth is on and Fuji iPhone is selected, then retry.")
        } else {
          update(.pairedFound, "Choose the paired X-T5 you want to reconnect.")
        }
      } catch {
        guard scanID == id, !Task.isCancelled else { return }
        update(.bluetoothFailed, Self.failureMessage(error, fallback: "Search stopped. Check Bluetooth and the camera’s Fuji iPhone destination, then retry."),
          failure: ManualWiFiEvent.Failure(error))
      }
    }
  }

  func reconnectNearby(_ camera: SavedCamera) {
    guard pairedNearby.contains(camera) else { return }
    connect(.saved(camera))
  }

  func scanForPairing() {
    guard canScan else { return }
    let id = UUID()
    scanID = id
    pairedNearby = []
    discovered = []
    update(.discovering, "On the camera, open Pairing Registration. Select the camera when it appears.")
    scanning = Task {
      defer { endScan(id) }
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
    if scanning != nil {
      guard case .discovered(let camera) = selection, discovered.contains(camera) else { return }
    }
    pairedNearby = []
    let replace = attempt != nil
    invalidateHandoff()
    let id = UUID()
    attempt = id
    update(.authenticating, "Connecting to the selected camera over Bluetooth…", linkMode: selection.linkMode)
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

        linkedCamera = LinkedCamera(identity: observed, peripheralID: selection.peripheralID, mode: selection.linkMode)
        operation = nil
        update(.bluetoothLinked, "Bluetooth link established. Camera registration has not been confirmed.",
          firmware: firmware, linkMode: selection.linkMode)
      } catch {
        guard attempt == id else { return }
        await finish(.bluetoothFailed, Self.failureMessage(error, fallback: "The camera connection stopped. Select it again to retry."),
          failure: ManualWiFiEvent.Failure(error), linkMode: selection.linkMode)
      }
    }
  }

  func confirmRegistration() {
    guard canConfirmRegistration, let mode = registrationMode else { return }
    registrationConfirmed = true
    update(.registrationConfirmed, "Camera registration confirmed by you. Start camera Wi-Fi when ready.", linkMode: mode)
  }

  func startWiFi() {
    guard canStartWiFi, let id = attempt, let linkedCamera else { return }
    let observed = linkedCamera.identity
    let firmware = ManualWiFiEvent.firmware(observed.firmware)
    update(.activating, "Starting the camera Wi-Fi network…", firmware: firmware, linkMode: linkedCamera.mode)
    operation = Task {
      do {
        try check(id)
        guard try await bluetooth.identity(for: observed.cameraID) == observed else { throw WirelessFailure.peerMismatch }
        try check(id)
        let selectionIsCurrent = currentSelectionCheck(id)
        try authorizeLaunch(linkedCamera.peripheralID, selectionIsCurrent)
        let network = try await bluetooth.activateWiFi(for: observed.cameraID)
        try check(id)
        guard network.credential.cameraID == observed.cameraID else { throw WirelessFailure.peerMismatch }
        let activationPassword = try await password(network.credential)
        guard try await bluetooth.identity(for: observed.cameraID) == observed else { throw WirelessFailure.peerMismatch }
        try check(id)
        handoff = network
        secret = activationPassword
        operation = nil
        update(.ready, "Camera Wi-Fi is ready. Join it in Settings, then return here.", firmware: firmware)
      } catch {
        guard attempt == id else { return }
        await finish(.activationFailed, Self.failureMessage(error, fallback: "The camera connection stopped. Select it again to retry."),
          failure: ManualWiFiEvent.Failure(error), linkMode: linkedCamera.mode)
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
    let trace = identityTrace?.begin()
    update(.identifying, "Reading the camera model and firmware over Wi-Fi…")
    operation = Task {
      do {
        try check(id)
        guard try await bluetooth.identity(for: identity.cameraID) == identity else { throw WirelessFailure.peerMismatch }
        try check(id)
        let observed = try await Self.readIdentity(identity, makeSession: makeSession, trace: trace)
        try check(id)
        guard self.handoff == handoff, userConfirmed,
          try await bluetooth.identity(for: identity.cameraID) == identity,
          observed.model == .xt5 else { throw WirelessFailure.peerMismatch }
        try check(id)
        let firmware = ManualWiFiEvent.firmware(observed.firmware)
        guard firmware != "unavailable" else { throw WirelessFailure.unsupportedFirmware }
        trace?(.init(.attempt, .completed))
        await finish(.identified, "X-T5 identified. Firmware \(firmware).", firmware: firmware)
      } catch {
        trace?(.init(.attempt, .failed, failure: .init(error)))
        guard attempt == id else { return }
        await finish(.identityFailed, Self.failureMessage(error, fallback: "Identity test failed. Check the camera network in Settings and retry."),
          failure: ManualWiFiEvent.Failure(error))
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
      pairedNearby = []
      guard canCancel else { return }
      guard handoff != nil, operation == nil else {
        retire(.leftDuringOperation, "The test stopped in the background. Select a camera to retry.")
        return
      }
      guard leaseID == nil else { return }
      if userConfirmed {
        userConfirmed = false
        update(.confirmationRequired, "Confirm the camera network again after returning from Settings.")
      }
      let id = UUID()
      leaseID = id
      let end = startLease { [weak self] expiration in
        self?.expireLease(id, reason: expiration)
      }
      guard leaseID == id else { end?(); return }
      endLease = end
      if end == nil { expireLease(id, reason: .hardDeadline) }
    @unknown default:
      if canCancel { retire(.leftDuringOperation, "The test stopped. Select a camera to retry.") }
    }
  }

  func bluetoothEvent(_ event: BluetoothGatewayEvent) {
    // The gateway delivers a terminal link error to the pending activation as well.
    // An in-flight activation owns that failure. An idle Bluetooth link or
    // an existing Wi-Fi handoff has no pending activation to retire it.
    guard attempt != nil, handoff != nil || (identity != nil && operation == nil) else { return }
    switch event {
    case .disconnected(let id, _) where identity?.cameraID == id:
      retire(.bluetoothLost, "Bluetooth connection lost. Check the camera and select it to retry.")
    case .availability(.poweredOff), .availability(.unsupported), .availability(.unauthorized):
      retire(.bluetoothLost, "Bluetooth connection lost. Check the camera and select it to retry.")
    default: break
    }
  }

  func waitForOperation() async { await operation?.value }
  func waitForScan() async { await scanning?.value }

  private func currentSelectionCheck(_ id: UUID) -> () -> Bool {
    { [weak self] in self?.attempt == id }
  }

  private func check(_ id: UUID) throws {
    try Task.checkCancellation()
    guard attempt == id else { throw CancellationError() }
  }

  private func endScan(_ id: UUID) {
    guard scanID == id else { return }
    scanID = nil
    scanning = nil
  }

  @discardableResult
  private func stopScan() -> Task<Void, Never>? {
    let pendingScan = scanning
    scanID = nil
    pendingScan?.cancel()
    scanning = nil
    discovered = []
    pairedNearby = []
    return pendingScan
  }

  private func releaseLease() {
    leaseID = nil
    let end = endLease
    endLease = nil
    end?()
  }

  private func expireLease(_ id: UUID, reason: LeaseExpiration) {
    guard leaseID == id else { return }
    if attempt != nil {
      retire(.leaseExpired, "The Settings handoff expired. Select the camera to retry.",
        releaseImmediately: reason == .hardDeadline)
    } else if reason == .hardDeadline {
      releaseLease()
    }
  }

  private func invalidateHandoff() {
    attempt = nil
    linkedCamera = nil
    handoff = nil
    secret = nil
    revealing = false
    registrationConfirmed = false
    userConfirmed = false
  }

  private func retire(_ phase: ManualWiFiEvent.Phase, _ message: String, releaseImmediately: Bool = false) {
    let pending = operation
    pending?.cancel()
    invalidateHandoff()
    // The watchdog leaves time for BLE teardown. The hard deadline ends the
    // assertion as soon as the attempt is invalid, even if teardown is pending.
    if releaseImmediately { releaseLease() }
    let pendingScan = stopScan()
    update(phase, message)
    operation = Task {
      await bluetooth.disconnect()
      releaseLease()
      await pendingScan?.value
      await pending?.value
      operation = nil
    }
  }

  private func finish(
    _ phase: ManualWiFiEvent.Phase, _ message: String,
    firmware: String? = nil, failure: ManualWiFiEvent.Failure? = nil,
    linkMode: ManualWiFiEvent.LinkMode? = nil
  ) async {
    invalidateHandoff()
    stopScan()
    await bluetooth.disconnect()
    update(phase, message, firmware: firmware, failure: failure, linkMode: linkMode)
    operation = nil
  }

  private func update(
    _ phase: ManualWiFiEvent.Phase, _ message: String,
    firmware: String? = nil, failure: ManualWiFiEvent.Failure? = nil,
    linkMode: ManualWiFiEvent.LinkMode? = nil
  ) {
    status = message
    record(ManualWiFiEvent(phase: phase, observedFirmware: firmware, failure: failure, linkMode: linkMode))
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

  private struct IdentityDeadlineReached: Error {}

  private static func readIdentity(
    _ expected: WirelessIdentity, makeSession: @escaping SessionFactory,
    trace: WirelessIdentityTrace.Observer?
  ) async throws -> WirelessIdentity {
    try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: WirelessIdentity.self) { group in
        group.addTask {
          let session = try await makeSession(expected, trace)
          let result: Result<WirelessIdentity, Error>
          do {
            try Task.checkCancellation()
            result = .success(try await session.open())
          } catch {
            result = .failure(error)
          }
          trace?(.init(.sessionCleanup, .waiting))
          do {
            try await Task { try await session.close() }.value
            trace?(.init(.sessionCleanup, .completed))
          } catch {
            trace?(.init(.sessionCleanup, .failed, failure: .init(error)))
            throw error
          }
          return try result.get()
        }
        group.addTask {
          try await Task.sleep(for: .seconds(20))
          trace?(.init(.identityTimerElapsed, .completed))
          throw IdentityDeadlineReached()
        }
        defer { group.cancelAll() }
        do {
          guard let identity = try await group.next() else { throw WirelessFailure.connectionLost }
          trace?(.init(.identityResult, .completed))
          return identity
        } catch is IdentityDeadlineReached {
          trace?(.init(.identityDeadline, .failed, failure: .outerDeadline))
          throw WirelessFailure.timeout(.transactionInactivity)
        } catch {
          trace?(.init(.identityResult, .failed, failure: .init(error)))
          throw error
        }
      }
    } onCancel: {
      trace?(.init(.identityCancellation, .failed, failure: .cancelled))
    }
  }
}

struct ManualWiFiEvent: Encodable {
  enum Phase: String, Encodable {
    case findingPaired, pairedFound, pairedNotFound, pairedAmbiguous
    case discovering, authenticating, bluetoothLinked, bluetoothFailed, registrationConfirmed, activating, activationFailed
    case ready, confirmationRequired, userConfirmed, identifying, identified, identityFailed
    case cancelled, leftDuringOperation, leaseExpired, bluetoothLost
  }

  enum LinkMode: String, Encodable { case pair, reconnect }
  enum LaunchMode: String, Encodable { case standard }

  enum Failure: String, Encodable {
    case wifiReadinessTimeout, tcpSetupTimeout, ptpTimeout, bluetoothPermission, localNetworkPermission
    case unsupportedProtocol, unsupportedFirmware, cameraBusy, peerMismatch, connectionLost, authentication
    case malformedData, other

    init(_ error: Error) {
      switch error as? WirelessFailure {
      case .timeout(.wifiReadiness): self = .wifiReadinessTimeout
      case .timeout(.tcpSetup): self = .tcpSetupTimeout
      case .timeout(.transactionInactivity): self = .ptpTimeout
      case .permissionDenied(.bluetooth): self = .bluetoothPermission
      case .permissionDenied(.localNetwork): self = .localNetworkPermission
      case .unsupportedProtocol: self = .unsupportedProtocol
      case .unsupportedFirmware: self = .unsupportedFirmware
      case .cameraBusy: self = .cameraBusy
      case .peerMismatch: self = .peerMismatch
      case .connectionLost: self = .connectionLost
      case .authentication: self = .authentication
      case .malformedData: self = .malformedData
      default: self = .other
      }
    }
  }

  let timestamp = Date()
  let phase: Phase
  let observedFirmware: String?
  let failure: Failure?
  let linkMode: LinkMode?
  let launchMode: LaunchMode?

  init(phase: Phase, observedFirmware: String?, failure: Failure?, linkMode: LinkMode?) {
    self.phase = phase
    self.observedFirmware = observedFirmware.map(Self.firmware)
    self.failure = failure
    self.linkMode = linkMode
    self.launchMode = switch phase {
    case .activating, .ready, .activationFailed: .standard
    default: nil
    }
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
    let clientName = ManualWiFiBluetoothDriver.phoneDestinationName
    let bluetoothTrace = ManualWiFiBluetoothTrace.live()
    let driver = ManualWiFiBluetoothDriver(trace: bluetoothTrace.append)
    let report = ManualWiFiReport()
    return ManualWiFiProbe(
      bluetooth: NativeBluetoothGateway(store: store, driver: driver),
      loadSaved: { try await store.cameras() },
      findPaired: { try await ManualPairedCameraFinder(saved: $0).find() },
      password: { try await store.password(for: $0) },
      authorizeLaunch: { try driver.beginStandardActivation(peripheralID: $0, selectionIsCurrent: $1) },
      makeSession: { identity, trace in
        let channel = try await NetworkByteChannel.connect(to: .cameraHosted(mode: .xApp), identityTrace: trace)
        return XAppTransferAdapter.makeSession(
          transport: WirelessPTPTransport(channel: channel, identityTrace: trace),
          expectedIdentity: identity, clientGUID: guid, clientName: clientName)
      },
      startLease: { expire in
        let app = UIApplication.shared
        let background = app.beginBackgroundTask(withName: "Camera Wi-Fi Settings handoff") {
          MainActor.assumeIsolated { expire(.hardDeadline) }
        }
        guard background != .invalid else { return nil }
        let timer = Task {
          do { try await Task.sleep(for: .seconds(25)) } catch { return }
          expire(.watchdog)
          do { try await Task.sleep(for: .seconds(3)) } catch { return }
          expire(.hardDeadline)
        }
        return {
          timer.cancel()
          app.endBackgroundTask(background)
        }
      },
      record: { report.append($0) }, identityTrace: .live())
  }
}
#endif
