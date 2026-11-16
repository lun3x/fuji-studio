#if DEBUG
import Foundation
import FujiCameraCore

/// The normal profile still owns authentication, firmware and the readiness notification.
@MainActor
final class ManualWiFiBluetoothDriver: BluetoothPeripheralDriver {
  static let phoneDestinationName = "Fuji iPhone"
  private static let identification = BLEGATTCharacteristic(
    service: "123d8f06-62a1-4935-9322-833c531ee225",
    characteristic: "85b9163e-62d1-49ff-a6f5-054b4630d4a1")

  private let native: any BluetoothPeripheralDriver
  private let trace: (Int, ManualWiFiBluetoothTrace.Event) -> Void
  private var link: (peripheralID: UUID, session: UUID, verifiedXT5: Bool)?
  private var activationGuard: ProbeImageViewingLaunch?
  private var attempt = 0
  // A terminal disconnect can arrive after the forwarding link has been cleared.
  private var traceSession: UUID?
  private var pendingSubscription: ManualWiFiBluetoothTrace.Subscription?
  private var readinessSamples: [ManualWiFiBluetoothTrace.Readiness: Int] = [:]
  var eventHandler: ((BluetoothDriverEvent) -> Void)?

  init(
    native: any BluetoothPeripheralDriver = CoreBluetoothDriver(),
    trace: @escaping (Int, ManualWiFiBluetoothTrace.Event) -> Void = { _, _ in }
  ) {
    self.native = native
    self.trace = trace
    native.eventHandler = { [weak self] in self?.receive($0) }
  }

  func beginStandardActivation(peripheralID: UUID, selectionIsCurrent: @escaping () -> Bool) throws {
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
    activationGuard = nil
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
    default: break
    }
    if var guardedLaunch = activationGuard {
      let decision = guardedLaunch.receive(event)
      activationGuard = guardedLaunch
      guard handle(decision, session: guardedLaunch.session) else { return }
    }
    if case .protocolEvent(_, let protocolEvent) = event { traceProtocolEvent(protocolEvent) }
    eventHandler?(event)
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
      // The shared guard recognized the profile's standard launch write.
      readinessSamples = [:]
      trace(attempt, .standard04Submitted)
      return true
    case .reject(let failure):
      trace(attempt, .activationRejected(.init(failure)))
      clear(session)
      eventHandler?(.linkFailed(session, failure))
    }
    return false
  }

  private func clear(_ session: UUID) {
    guard link?.session == session else { return }
    link = nil
    activationGuard = nil
  }
}
#endif
