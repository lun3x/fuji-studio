#if DEBUG
import Foundation
import FujiCameraCore

/// The normal profile still owns authentication, firmware and the readiness notification.
@MainActor
final class ManualWiFiBluetoothDriver: BluetoothPeripheralDriver {
  typealias RetryScheduler = @MainActor (Duration, @escaping @MainActor () -> Void) -> () -> Void

  static let phoneDestinationName = "Fuji iPhone"
  private static let identification = BLEGATTCharacteristic(
    service: "123d8f06-62a1-4935-9322-833c531ee225",
    characteristic: "85b9163e-62d1-49ff-a6f5-054b4630d4a1")
  private static let maximumLaunchWrites = 3

  private enum ImageViewing {
    case awaitingAcknowledgment(ordinal: Int, earlyStatus: Data?)
    case awaitingReadiness(ordinal: Int)
    case delaying(nextOrdinal: Int, token: UUID)
    case finished
  }

  private let native: any BluetoothPeripheralDriver
  private let trace: (Int, ManualWiFiBluetoothTrace.Event) -> Void
  private let writesReferenceAppFlags: Bool
  private let scheduleRetry: RetryScheduler
  private var link: (peripheralID: UUID, session: UUID, verifiedXT5: Bool)?
  private var activationGuard: ProbeImageViewingLaunch?
  private var imageViewing: ImageViewing?
  private var cancelRetry: (() -> Void)?
  private var attempt = 0
  // A terminal disconnect can arrive after the forwarding link has been cleared.
  private var traceSession: UUID?
  private var pendingSubscription: ManualWiFiBluetoothTrace.Subscription?
  private var appFlags: [BLEGATTCharacteristic] = []
  private var pendingAppFlag: (index: Int, characteristic: BLEGATTCharacteristic)?
  private var readinessSamples: [ManualWiFiBluetoothTrace.Readiness: Int] = [:]
  var eventHandler: ((BluetoothDriverEvent) -> Void)?

  init(
    native: any BluetoothPeripheralDriver = CoreBluetoothDriver(),
    trace: @escaping (Int, ManualWiFiBluetoothTrace.Event) -> Void = { _, _ in },
    writesReferenceAppFlags: Bool = false,
    scheduleRetry: @escaping RetryScheduler = ManualWiFiBluetoothDriver.scheduleOnMainActor
  ) {
    self.native = native
    self.trace = trace
    self.writesReferenceAppFlags = writesReferenceAppFlags
    self.scheduleRetry = scheduleRetry
    native.eventHandler = { [weak self] in self?.receive($0) }
  }

  func beginImageViewingActivation(peripheralID: UUID, selectionIsCurrent: @escaping () -> Bool) throws {
    guard let link, link.peripheralID == peripheralID, link.verifiedXT5,
      selectionIsCurrent(), activationGuard == nil
    else {
      if link != nil { trace(attempt, .activationRejected(.peerMismatch)) }
      throw WirelessFailure.peerMismatch
    }
    activationGuard = ProbeImageViewingLaunch(session: link.session, selectionIsCurrent: selectionIsCurrent)
    trace(attempt, .activationAuthorized)
  }

  func start(allowPermissionPrompt: Bool) throws { try native.start(allowPermissionPrompt: allowPermissionPrompt) }
  func scan() { native.scan() }
  func stopScan() { native.stopScan() }
  func discardDiscoveries() { native.discardDiscoveries() }

  func connect(peripheralID: UUID, session: UUID) {
    resetActivation()
    appFlags = []
    pendingAppFlag = nil
    link = (peripheralID, session, false)
    attempt += 1
    traceSession = session
    pendingSubscription = nil
    readinessSamples = [:]
    trace(attempt, .connectionRequested)
    native.connect(peripheralID: peripheralID, session: session)
  }

  func disconnect(session: UUID) {
    if traceSession == session { trace(attempt, .disconnectRequested) }
    clear(session)
    native.disconnect(session: session)
  }

  func perform(_ action: BLEProtocolAction, session: UUID) {
    guard link?.session == session else { return }
    if var guardedLaunch = activationGuard {
      let decision = guardedLaunch.perform(action, session: session)
      activationGuard = guardedLaunch
      guard handle(decision, session: session) else { return }
    } else if case .write(_, _, .activateWiFi) = action {
      trace(attempt, .activationRejected(.unsupportedProtocol))
      eventHandler?(.linkFailed(session, .unsupportedProtocol))
      return
    }
    if link?.verifiedXT5 == true,
      case .write(Self.identification, let bytes, .identify) = action,
      bytes == Data("Fuji Studio".utf8)
    {
      native.perform(.write(Self.identification, Data(Self.phoneDestinationName.utf8), .identify), session: session)
      return
    }
    switch action {
    case .subscribe(let characteristic):
      pendingSubscription = ManualWiFiBluetoothTrace.Subscription(characteristic)
      if let pendingSubscription { trace(attempt, .subscription(pendingSubscription, .requested)) }
    case .read(ProbeImageViewingLaunch.password):
      trace(attempt, .passwordReadRequested)
    default: break
    }
    native.perform(action, session: session)
  }

  private func receive(_ event: BluetoothDriverEvent) {
    switch event {
    case .peerModel(let session, let model) where link?.session == session:
      let known = model.flatMap(WirelessCameraModel.init(bluetoothModelNumber:))
      link?.verifiedXT5 = known == .xt5
      let label: ManualWiFiBluetoothTrace.PeerModel = switch known {
      case .xt5: .xt5
      case .xe3: .xe3
      case nil: model == nil ? .unavailable : .unrecognized
      }
      trace(attempt, .peerModel(label))
      if known != .xt5, activationGuard != nil {
        rejectActivation(.peerMismatch, session: session)
        return
      }
    case .linkFailed(let session, let failure):
      if traceSession == session { trace(attempt, .linkFailed(.init(failure))) }
      clear(session)
    case .disconnected(let session, let failure):
      if traceSession == session {
        trace(attempt, .disconnected(.init(failure)))
        traceSession = nil
      }
      clear(session)
    case .protocolEvent(let session, _) where link?.session != session:
      return
    case .protocolEvent(let session, let protocolEvent):
      traceProtocolEvent(protocolEvent)
      if writesReferenceAppFlags, handleAppFlagSetup(protocolEvent, session: session) { return }
      if let activationGuard {
        guard isCurrent(activationGuard, session: session) else {
          rejectActivation(.peerMismatch, session: session)
          return
        }
        if case .failed = protocolEvent {
          clear(session)
        } else if consumeImageViewingEvent(protocolEvent, session: session) {
          return
        }
      }
    default: break
    }
    forward(event)
  }

  /// Hold the identity-write callback until both reference flag writes complete.
  private func handleAppFlagSetup(_ event: BLEProtocolEvent, session: UUID) -> Bool {
    switch event {
    case .services(let characteristics):
      guard link?.verifiedXT5 == true else {
        eventHandler?(.linkFailed(session, .peerMismatch))
        return true
      }
      appFlags = []
      for (index, uuid) in XT5BLEProfile.appFlagUUIDs.enumerated() {
        let matches = characteristics.filter { $0.characteristic == uuid }
        guard matches.count == 1, let flag = matches.first else {
          trace(attempt, .appFlagUnavailable(ordinal: index + 1))
          eventHandler?(.linkFailed(session, .unsupportedProtocol))
          return true
        }
        appFlags.append(flag)
      }
      return false
    case .wrote(Self.identification) where !appFlags.isEmpty:
      writeAppFlag(at: 0, session: session)
      return true
    case .wrote(let characteristic):
      guard let pendingAppFlag, pendingAppFlag.characteristic == characteristic else { return false }
      let index = pendingAppFlag.index
      trace(attempt, .appFlagAcknowledged(ordinal: index + 1))
      if index + 1 < appFlags.count {
        writeAppFlag(at: index + 1, session: session)
      } else {
        self.pendingAppFlag = nil
        forward(.protocolEvent(session, .wrote(Self.identification)))
      }
      return true
    case .failed(let characteristic, let failure):
      guard let pendingAppFlag, pendingAppFlag.characteristic == characteristic else { return false }
      self.pendingAppFlag = nil
      trace(attempt, .appFlagFailed(ordinal: pendingAppFlag.index + 1, .init(failure)))
      return false
    default: return false
    }
  }

  private func writeAppFlag(at index: Int, session: UUID) {
    let characteristic = appFlags[index]
    pendingAppFlag = (index, characteristic)
    trace(attempt, .appFlagSubmitted(ordinal: index + 1))
    native.perform(.write(characteristic, Data([0x01]), .identify), session: session)
  }

  private func forward(_ event: BluetoothDriverEvent) {
    if var guardedLaunch = activationGuard {
      let decision = guardedLaunch.receive(event)
      activationGuard = guardedLaunch
      guard handle(decision, session: guardedLaunch.session) else { return }
    }
    eventHandler?(event)
  }

  private func consumeImageViewingEvent(_ event: BLEProtocolEvent, session: UUID) -> Bool {
    let readiness = ManualWiFiBluetoothTrace.Subscription.readiness.characteristic
    switch event {
    case .wrote(ProbeImageViewingLaunch.launch):
      guard let imageViewing else { return false }
      guard case .awaitingAcknowledgment(let ordinal, let earlyStatus) = imageViewing else { return true }
      self.imageViewing = .awaitingReadiness(ordinal: ordinal)
      // The profile issued one write and expects a single acknowledgement.
      if ordinal == 1 { forward(.protocolEvent(session, event)) }
      if let earlyStatus, link?.session == session {
        receiveReadiness(earlyStatus, characteristic: readiness, session: session)
      }
      return true
    case .notification(readiness, let bytes):
      receiveReadiness(bytes, characteristic: readiness, session: session)
      return true
    default: return false
    }
  }

  private func receiveReadiness(_ bytes: Data, characteristic: BLEGATTCharacteristic, session: UUID) {
    let status = ManualWiFiBluetoothTrace.Readiness(bytes)
    switch (imageViewing, status) {
    case (.awaitingAcknowledgment(let ordinal, let earlyStatus), .positive):
      if earlyStatus?.first != 1 {
        imageViewing = .awaitingAcknowledgment(ordinal: ordinal, earlyStatus: bytes)
      }
    case (.awaitingAcknowledgment(let ordinal, nil), .negative):
      imageViewing = .awaitingAcknowledgment(ordinal: ordinal, earlyStatus: bytes)
    case (.awaitingReadiness, .positive), (.delaying, .positive):
      imageViewing = .finished
      cancelPendingRetry()
      forward(.protocolEvent(session, .notification(characteristic, bytes)))
    case (.awaitingReadiness(let ordinal), .negative):
      if ordinal == Self.maximumLaunchWrites {
        imageViewing = .finished
        trace(attempt, .imageViewingRetriesExhausted)
        forward(.protocolEvent(session, .notification(characteristic, bytes)))
      } else {
        waitToRetry(ordinal: ordinal + 1, session: session)
      }
    default: break
    }
  }

  private func waitToRetry(ordinal: Int, session: UUID) {
    let token = UUID()
    imageViewing = .delaying(nextOrdinal: ordinal, token: token)
    trace(attempt, .imageViewingRetryScheduled(ordinal: ordinal))
    cancelRetry = scheduleRetry(.milliseconds(200)) { [weak self] in
      guard let self, case .delaying(let ordinal, let pendingToken) = self.imageViewing,
        pendingToken == token, let activationGuard = self.activationGuard
      else { return }
      guard self.isCurrent(activationGuard, session: session) else {
        self.rejectActivation(.peerMismatch, session: session)
        return
      }
      self.cancelRetry = nil
      self.submitImageViewing(ordinal: ordinal, session: session)
    }
  }

  private static func scheduleOnMainActor(
    _ delay: Duration, _ callback: @escaping @MainActor () -> Void
  ) -> () -> Void {
    let task = Task { @MainActor in
      do { try await Task.sleep(for: delay) } catch { return }
      guard !Task.isCancelled else { return }
      callback()
    }
    return { task.cancel() }
  }

  private func traceProtocolEvent(_ event: BLEProtocolEvent) {
    typealias Subscription = ManualWiFiBluetoothTrace.Subscription
    switch event {
    case .services(let characteristics):
      for label in Subscription.allCases where !characteristics.contains(label.characteristic) {
        trace(attempt, .subscription(label, .notDiscovered))
      }
    case .subscribed(let characteristic), .subscriptionUnavailable(let characteristic):
      guard let label = Subscription(characteristic) else { return }
      if pendingSubscription == label { pendingSubscription = nil }
      if case .subscribed = event {
        trace(attempt, .subscription(label, .accepted))
      } else {
        trace(attempt, .subscription(label, .unavailable))
      }
    case .read(ProbeImageViewingLaunch.password, _):
      trace(attempt, .passwordReadCompleted)
    case .wrote(ProbeImageViewingLaunch.launch):
      trace(attempt, .launchWriteAcknowledged)
    case .notification(Subscription.readiness.characteristic, let bytes):
      let status = ManualWiFiBluetoothTrace.Readiness(bytes)
      let count = readinessSamples[status, default: 0]
      guard count < 8 else { return }
      readinessSamples[status] = count + 1
      trace(attempt, .readiness(status, length: min(bytes.count, BLEProtocolEvent.maximumAttributeBytes)))
    case .failed(ProbeImageViewingLaunch.password, let failure):
      trace(attempt, .passwordReadFailed(.init(failure)))
    case .failed(ProbeImageViewingLaunch.launch, let failure):
      trace(attempt, .launchWriteFailed(.init(failure)))
    case .failed(let characteristic, _) where pendingSubscription?.characteristic == characteristic:
      if let pendingSubscription { trace(attempt, .subscription(pendingSubscription, .failed)) }
      pendingSubscription = nil
    default: break
    }
  }

  private func handle(_ decision: ProbeImageViewingLaunch.Decision, session: UUID) -> Bool {
    switch decision {
    case .forward:
      return true
    case .ignore:
      break
    case .submitImageViewing:
      readinessSamples = [:]
      submitImageViewing(ordinal: 1, session: session)
    case .reject(let failure):
      rejectActivation(failure, session: session)
    }
    return false
  }

  private func submitImageViewing(ordinal: Int, session: UUID) {
    imageViewing = .awaitingAcknowledgment(ordinal: ordinal, earlyStatus: nil)
    trace(attempt, .imageViewing03Submitted(ordinal: ordinal))
    native.perform(.write(ProbeImageViewingLaunch.launch, Data([0x03, 0x00]), .activateWiFi), session: session)
  }

  private func isCurrent(_ guardState: ProbeImageViewingLaunch, session: UUID) -> Bool {
    link?.session == session && link?.verifiedXT5 == true && guardState.session == session
      && guardState.selectionIsCurrent()
  }

  private func rejectActivation(_ failure: WirelessFailure, session: UUID) {
    trace(attempt, .activationRejected(.init(failure)))
    clear(session)
    eventHandler?(.linkFailed(session, failure))
  }

  private func cancelPendingRetry() {
    let cancel = cancelRetry
    cancelRetry = nil
    cancel?()
  }

  private func resetActivation() {
    activationGuard = nil
    imageViewing = nil
    cancelPendingRetry()
  }

  private func clear(_ session: UUID) {
    guard link?.session == session else { return }
    link = nil
    appFlags = []
    pendingAppFlag = nil
    resetActivation()
  }
}
#endif
