#if DEBUG
import CryptoKit
import Foundation
import FujiCameraCore
import Observation
import SwiftUI

struct WirelessProbeFirmwareEvidence: Codable, Sendable {
  let model: WirelessCameraModel
  let source: Source
  let transferFirmware: String?
  let bluetoothFirmware: String?
  var observedAt = Date()

  enum Source: String, Codable, Sendable { case cameraNetwork, autoSave }

  private enum CodingKeys: String, CodingKey {
    case model, source, transferFirmware, bluetoothFirmware, observedAt
  }

  static func record(_ observation: Self, in folder: URL) throws {
    let file = folder.appending(path: "private-firmware-\(UUID().uuidString).json")
    try JSONEncoder().encode(observation).write(to: file, options: [.atomic, .completeFileProtection])
  }
}

/// This route constructs Bluetooth and Wi-Fi services only.
struct WirelessProtocolProbe: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var probe: WirelessProbeModel
  private let bluetoothOnly: Bool

  init(bluetoothOnly: Bool) {
    self.bluetoothOnly = bluetoothOnly
    _probe = State(initialValue: WirelessProbeModel(bluetoothOnly: bluetoothOnly))
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("Disconnect the camera’s USB cable. Select one camera here and approve its prompts.")
          if bluetoothOnly {
            Text("Bluetooth-only diagnostics. This build cannot join camera Wi-Fi.")
          } else {
            Text("Check the camera’s Resize Image for Smartphone setting before testing originals.")
          }
          Text("Run \(probe.runID.uuidString)").font(.caption).textSelection(.enabled)
          Text(probe.status).textSelection(.enabled)
        }
        Section("Cameras") {
          Button("Discover cameras") { Task { await probe.coordinator.startDiscovery() } }
          ForEach(probe.state.discoveredCameras) { camera in
            Button("Pair \(camera.displayName)") { Task { await probe.coordinator.pair(camera) } }
          }
          ForEach(probe.state.savedCameras) { camera in
            Button {
              Task { await probe.select(camera.id) }
            } label: {
              Label(
                camera.displayName, systemImage: probe.state.selectedCameraID == camera.id
                  ? "checkmark.circle.fill" : "circle")
            }
          }
          Text("Bluetooth \(String(describing: probe.state.bluetooth))")
          Button("Retry Bluetooth") { Task { await probe.coordinator.retryBluetooth() } }
          if !bluetoothOnly {
            Button("Connect selected camera Wi-Fi") { Task { await probe.coordinator.connectWiFi() } }
              .disabled(probe.state.selectedCameraID == nil || probe.state.wifi != .idle)
            Text("Wi-Fi \(String(describing: probe.state.wifi))")
          }
          Button("Disconnect") { Task { await probe.coordinator.cancelConnection() } }
        }
        if !bluetoothOnly, probe.isSelectedXE3 {
          Section("PC Auto Save") {
            if probe.autoSaveAvailable {
              Text("Connect the X-E3 and iPhone to the same Wi-Fi network with client isolation disabled.")
              switch probe.state.wifi {
              case .registeringAutoSave:
                Text("Start PC AUTO SAVE SETTING on the X-E3 and choose FujiStudio on the camera.")
              case .verifyingAutoSave, .waitingForAutoSave:
                Text("Start PC AUTO SAVE in the camera’s playback menu and choose the FujiStudio destination.")
              default:
                if let cameraID = probe.state.selectedCameraID,
                  probe.state.verifiedAutoSaveCameraID == cameraID
                {
                  Text("Destination verified for the selected X-E3.")
                }
              }
              Button("Set up PC Auto Save") { Task { await probe.coordinator.setUpAutoSave() } }
                .disabled(probe.state.wifi != .idle)
              Button("Wait for PC Auto Save") { Task { await probe.coordinator.waitForAutoSave() } }
                .disabled(probe.state.wifi != .idle)
            } else {
              Text("PC Auto Save needs a build signed with Apple’s Multicast Networking capability.")
            }
          }
        }
        if probe.state.wifi == .ready {
          Section("Camera inventory") {
            Button("Read inventory") { Task { await probe.readInventory() } }
              .disabled(probe.working)
            if let capability = probe.capability {
              Text("RAW \(String(describing: capability.rawExposure))")
              Text(capability.originalSizeVerified ? "Original-size control observed" : "Original size unverified")
              if capability.mode == .xApp, !capability.originalSizeVerified {
                Text("XApp originals require a readable original-size setting. The probe leaves that setting as found.")
              }
              if capability.mode != .xApp {
                Text("Compare the diagnostic candidate hashes with independent card copies.")
              }
            }
            ForEach(probe.files.indices, id: \.self) { index in
              let file = probe.files[index]
              if file.format == .raf || file.format == .jpeg {
                Button {
                  probe.toggle(file)
                } label: {
                  Label(file.filename, systemImage: probe.selected.contains(file) ? "checkmark.circle.fill" : "circle")
                }
              } else {
                Text(file.filename)
              }
            }
            Button(probe.capability?.mode == .xApp
              ? "Stage selected originals privately" : "Stage selected diagnostic candidates") {
              Task { await probe.downloadSelection() }
            }
              .disabled(probe.selected.isEmpty || probe.working)
          }
        }
      }
      .navigationTitle("Wireless protocol probe")
    }
    .task { await probe.observe() }
    .onChange(of: scenePhase, initial: true) { _, phase in
      Task {
        switch phase {
        case .active: await probe.coordinator.setActivity(.active)
        case .inactive: await probe.coordinator.setActivity(.inactive)
        case .background: await probe.coordinator.setActivity(.background)
        @unknown default: await probe.coordinator.setActivity(.inactive)
        }
      }
    }
  }
}

@MainActor
@Observable
private final class WirelessProbeModel {
  let runID = UUID()
  let coordinator: WirelessConnectionCoordinator
  private let autoSaveGateway: NativeAutoSaveGateway?
  var state = WirelessConnectionState()
  var files: [WirelessObjectDescriptor] = []
  var selected: Set<WirelessObjectDescriptor> = []
  var status = "Select a camera to begin."
  var capability: WirelessCapabilities?
  var working = false
  var autoSaveAvailable = false

  var isSelectedXE3: Bool {
    state.savedCameras.contains { $0.id == state.selectedCameraID && $0.model == .xe3 }
  }

  init(bluetoothOnly: Bool) {
    let suite = "com.lun3x.FujiStudio.wireless-protocol-probe"
    let defaults = UserDefaults(suiteName: suite)!
    let store = KeychainCameraStore(defaults: defaults, service: suite)
    let gateway = bluetoothOnly ? nil : NativeWiFiJoinGateway(credentials: store)
    let clientID = defaults.string(forKey: "clientID").flatMap(UUID.init(uuidString:)) ?? UUID()
    defaults.set(clientID.uuidString, forKey: "clientID")
    let guid = withUnsafeBytes(of: clientID.uuid) { Data($0) }
    let autoSave = bluetoothOnly ? nil : NativeAutoSaveGateway(store: store, clientGUID: guid)
    autoSaveGateway = autoSave

    let driver = CoreBluetoothDriver()
    if bluetoothOnly {
      driver.observePairing = { [runID] observation in
        Self.record(observation, for: runID)
      }
      driver.observeUnrecognizedModel = { [runID] model in
        guard let folder = try? Self.runFolder(for: runID) else { return }
        let file = folder.appending(path: "private-bluetooth-model.json")
        try? JSONEncoder().encode(model).write(to: file, options: [.atomic, .completeFileProtection])
      }
    }

    coordinator = WirelessConnectionCoordinator(
      bluetooth: NativeBluetoothGateway(store: store, driver: driver), store: store,
      wifi: gateway, ownership: bluetoothOnly ? nil : ProbeCameraOwnership(),
      sessionFactory: { identity, _ in
        let mode: WirelessMode = identity.model == .xt5 ? .xApp : .phone
        let channel = try await NetworkByteChannel.connect(to: .cameraHosted(mode: mode))
        let transport = WirelessPTPTransport(channel: channel)
        switch identity.model {
        case .xt5:
          return XAppTransferAdapter.makeSession(
            transport: transport, expectedIdentity: identity, clientGUID: guid)
        case .xe3:
          return PhoneTransferAdapter.makeSession(
            transport: transport, expectedIdentity: identity, clientGUID: guid)
        }
      }, autoSave: autoSave)
  }

  func observe() async {
    let captureFirmware: @Sendable (WirelessProbeFirmwareEvidence) -> Void = { [runID] observation in
      guard let folder = try? Self.runFolder(for: runID) else { return }
      try? WirelessProbeFirmwareEvidence.record(observation, in: folder)
    }
    await coordinator.observeProbeFirmware(captureFirmware)
    if let autoSaveGateway {
      await autoSaveGateway.observeProbeFirmware(captureFirmware)
      autoSaveAvailable = (try? await autoSaveGateway.checkAvailability()) != nil
    }
    for await update in await coordinator.states() {
      let previous = state
      state = update
      if update.wifi != .ready, previous.wifi == .ready {
        files.removeAll()
        selected.removeAll()
        capability = nil
      }
      if previous.bluetooth != update.bluetooth || previous.wifi != update.wifi
        || previous.wifiFailure != update.wifiFailure || previous.failure != update.failure
      {
        let reported = update.wifiFailure ?? update.failure
        let phase = update.wifiFailurePhase ?? update.wifi
        let observation = reported.map { "Wireless \(phase): \($0)" }
          ?? "Bluetooth \(update.bluetooth), Wi-Fi \(update.wifi)"
        record(observation)
        if let reported { status = Self.safeMessage(reported) + " (\(phase))" }
      }
      if previous.wifi != .ready, update.wifi == .ready {
        do {
          let session = try await coordinator.transferSession()
          let identity = try await session.open()
          let policy = WirelessSupportPolicy()
          let firmware = policy.assess(model: identity.model.rawValue, firmware: identity.firmware)
            == .supported(identity.model) ? policy.record(for: identity.model).firmware : "unverified"
          let serial = identity.protocolPeerKey != nil ? "present" : "absent"
          status = "\(identity.model.rawValue) \(firmware) ready. DeviceInfo serial field \(serial)."
          capability = try await session.capabilities()
          record(status)
        } catch { status = Self.safeMessage(error) }
      }
      if update.pairingFailure != nil {
        status = "Pairing stopped because the camera model could not be identified."
      }
    }
  }

  func select(_ id: WirelessCameraID) async {
    do { try await coordinator.select(id) } catch { status = Self.safeMessage(error) }
  }

  func toggle(_ file: WirelessObjectDescriptor) {
    if !selected.insert(file).inserted { selected.remove(file) }
  }

  func readInventory() async {
    guard !working else { return }
    working = true
    defer { working = false }
    files.removeAll()
    selected.removeAll()
    do {
      let session = try await coordinator.transferSession()
      var inventory = WirelessStorageInventory()
      for try await batch in try await session.enumerate() {
        guard state.wifi == .ready else { return }
        files += batch.objects
        inventory.apply(batch)
      }
      capability = try await session.capabilities()
      let storages = inventory.storage.sorted { $0.key < $1.key }
        .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
      status = "\(files.count) objects. Storage \(storages). RAW \(inventory.rawExposure)."
      record(status)
    } catch { status = Self.safeMessage(error) }
  }

  func downloadSelection() async {
    guard !working else { return }
    let selection = files.filter { selected.contains($0) }
    guard !selection.isEmpty else { return }
    working = true
    defer { working = false }
    do {
      let session = try await coordinator.transferSession()
      let capabilities = try await session.capabilities()
      let diagnostic: (any WirelessDiagnosticCandidateSession)?
      let representation: ProbeStagedFile.Representation
      if capabilities.mode != .xApp {
        guard let candidateSession = session as? any WirelessDiagnosticCandidateSession else {
          throw WirelessFailure.unsupportedProtocol
        }
        diagnostic = candidateSession
        representation = capabilities.mode == .autoSave ? .autoSaveDiagnosticCandidate : .phoneDiagnosticCandidate
      } else {
        diagnostic = nil
        representation = .xAppOriginalSizeControlObserved
      }
      let folder = try runFolder()
      var count = 0
      for object in selection {
        let file = try ProbeStagedFile(folder: folder, object: object)
        do {
          if let diagnostic {
            try await diagnostic.downloadDiagnosticCandidate(object) { try await file.append($0) }
          } else {
            try await session.download(object) { try await file.append($0) }
          }
          let receipt = try await file.finish(representation: representation)
          count += 1
          let kind = diagnostic == nil ? "originals in XApp original-size mode" : "diagnostic candidates"
          status = "Staged \(count) of \(selection.count) \(kind). SHA-256 \(receipt.sha256)."
          record("Staged \(representation.rawValue), \(receipt.byteLength) bytes, SHA-256 \(receipt.sha256).")
        } catch {
          await file.discard()
          throw error
        }
      }
    } catch {
      status = Self.safeMessage(error)
      record(status)
    }
  }

  private func runFolder() throws -> URL { try Self.runFolder(for: runID) }

  nonisolated private static func runFolder(for runID: UUID) throws -> URL {
    let support = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    var folder = support.appending(path: "WirelessProtocolProbe/\(runID.uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try folder.setResourceValues(values)
    return folder
  }

  private func record(_ observation: String) {
    Self.record(observation, for: runID)
  }

  private static func record(_ observation: String, for runID: UUID) {
    guard let folder = try? runFolder(for: runID) else { return }
    let file = folder.appending(path: "observations.txt")
    let line = Data("\(Date().formatted(.iso8601)) \(observation)\n".utf8)
    if !FileManager.default.fileExists(atPath: file.path) {
      _ = FileManager.default.createFile(
        atPath: file.path, contents: line,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    } else if let output = try? FileHandle(forWritingTo: file) {
      defer { try? output.close() }
      _ = try? output.seekToEnd()
      try? output.write(contentsOf: line)
    }
  }

  private static func safeMessage(_ error: any Error) -> String {
    if let failure = error as? WirelessFailure {
      switch failure {
      case .originalSizeUnavailable: return "The camera’s original-size setting could not be verified."
      case .autoSaveEntitlementUnavailable: return "This build needs Apple’s Multicast Networking capability."
      case .autoSaveIdentityUnavailable: return "PC Auto Save needs an independently verified identity for this X-E3."
      case .autoSaveRegistrationRequired: return "Set up a PC Auto Save destination for the selected camera first."
      case .autoSavePeerUnreachable:
        return "The camera was detected, but the connection failed. Check for Wi-Fi client isolation."
      case .permissionDenied(.localNetwork): return "Allow Fuji Studio to access the Local Network in Settings."
      case .timeout(.autoSaveRegistration), .timeout(.autoSaveSession):
        return "PC Auto Save timed out. Check the camera menu and use the same Wi-Fi network on both devices."
      default: return "Wireless failure \(failure)"
      }
    }
    if let error = error as? PTPError {
      if case .responseCode(let code) = error { return "PTP response \(String(code, radix: 16))" }
      if case .sessionFailure = error { return "PTP initialization or session failed." }
      return "PTP failure \(error)"
    }
    if error is CancellationError { return "Cancelled." }
    return "Probe failed."
  }
}

private actor ProbeCameraOwnership: WirelessCameraOwnershipGateway {
  private var current: CameraUseLease?

  func acquireWireless() throws -> CameraUseLease {
    guard current == nil else { throw WirelessFailure.cameraBusy }
    let lease = CameraUseLease()
    current = lease
    return lease
  }

  func releaseWireless(_ lease: CameraUseLease) {
    if current == lease { current = nil }
  }
}

private actor ProbeStagedFile {
  enum Representation: String, Encodable, Sendable {
    case phoneDiagnosticCandidate
    case autoSaveDiagnosticCandidate
    case xAppOriginalSizeControlObserved
  }

  struct Receipt: Encodable, Sendable {
    let storageID: UInt32
    let name: String
    let directory: String?
    let storedFile: String
    let byteLength: UInt64
    let sha256: String
    let representation: Representation
  }

  private let file: URL
  private let object: WirelessObjectDescriptor
  private let handle: FileHandle
  private var count: UInt64 = 0
  private var hash = SHA256()

  init(folder: URL, object: WirelessObjectDescriptor) throws {
    self.object = object
    file = folder.appending(path: UUID().uuidString)
      .appendingPathExtension(object.format == .raf ? "raf" : "jpg")
    guard FileManager.default.createFile(
      atPath: file.path, contents: nil,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    else { throw WirelessFailure.unavailableStorage }
    do {
      handle = try FileHandle(forWritingTo: file)
    } catch {
      try? FileManager.default.removeItem(at: file)
      throw error
    }
  }

  func append(_ bytes: Data) throws {
    try Task.checkCancellation()
    guard UInt64(bytes.count) <= object.byteLength - count else { throw WirelessFailure.malformedData }
    try handle.write(contentsOf: bytes)
    count += UInt64(bytes.count)
    hash.update(data: bytes)
  }

  func finish(representation: Representation) throws -> Receipt {
    guard count == object.byteLength else { throw WirelessFailure.malformedData }
    try handle.synchronize()
    try handle.close()
    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    let receipt = Receipt(
      storageID: object.storageID, name: object.filename, directory: object.directory,
      storedFile: file.lastPathComponent, byteLength: count, sha256: digest,
      representation: representation)
    let metadata = file.deletingPathExtension().appendingPathExtension("json")
    try JSONEncoder().encode(receipt).write(to: metadata, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    return receipt
  }

  func discard() {
    try? handle.close()
    try? FileManager.default.removeItem(at: file)
  }
}
#endif
