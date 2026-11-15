import Foundation
import FujiCameraCore

@MainActor
final class ProbeRegistrationBluetoothDriver: BluetoothPeripheralDriver {
  private enum Step {
    case awaitingConnection
    case awaitingModel(UUID)
    case awaitingRead(UUID)
    case awaitingStatus(UUID)
    case awaitingAcknowledgement(UUID, Data)
    case acknowledged(UUID)
    case rejected(UUID)

    var session: UUID? {
      switch self {
      case .awaitingConnection: nil
      case .awaitingModel(let id), .awaitingRead(let id), .awaitingStatus(let id),
        .awaitingAcknowledgement(let id, _), .acknowledged(let id), .rejected(let id): id
      }
    }
  }

  private struct Experiment {
    let ticket: ProbeSecureStatusComparison.RegistrationTicket
    let selectionIsCurrent: () -> Bool
    var step = Step.awaitingConnection
  }

  private let native: any BluetoothPeripheralDriver
  private var experiment: Experiment?
  private var geotagSubscription: ProbeGeotagSubscription?
  private var registrationNotifications = ProbeRegistrationNotifications()
  private(set) var acknowledgementUsed = false
  private(set) var geotagSubscriptionAcknowledged = false
  private(set) var geotagSubscriptionFailure: ProbeGeotagSubscription.Failure?
  var eventHandler: ((BluetoothDriverEvent) -> Void)?
  var observeAcknowledgement: (() -> Void)?
  var flushRegistrationNotifications: (([ProbeRegistrationNotificationEntry]) -> Void)?

  init(native: any BluetoothPeripheralDriver) {
    self.native = native
    native.eventHandler = { [weak self] event in self?.receive(event) }
  }

  @discardableResult
  func beginExperiment(
    _ ticket: ProbeSecureStatusComparison.RegistrationTicket, selectionIsCurrent: @escaping () -> Bool
  ) -> Bool {
    guard geotagSubscription == nil else { return false }
    experiment = Experiment(ticket: ticket, selectionIsCurrent: selectionIsCurrent)
    return true
  }

  func endExperiment() { experiment = nil }
  func resetObservation() {
    acknowledgementUsed = false
    geotagSubscriptionAcknowledged = false
    geotagSubscriptionFailure = nil
  }

  func beginGeotagSubscription(peripheralID: UUID) -> Bool {
    guard experiment == nil, geotagSubscription == nil else { return false }
    geotagSubscription = ProbeGeotagSubscription(peripheralID: peripheralID)
    return true
  }

  func cancelGeotagSubscription() { geotagSubscription?.cancel() }
  func retireGeotagSubscription() { geotagSubscription = nil }

  func beginRegistrationObservation(peripheralID: UUID) {
    registrationNotifications.begin(peripheralID: peripheralID)
  }

  func markRegistrationObservationReady(peripheralID: UUID) {
    registrationNotifications.markReady(peripheralID: peripheralID)
  }

  func endRegistrationObservation() { registrationNotifications.pause() }

  func start(allowPermissionPrompt: Bool) throws {
    if let experiment, !experiment.selectionIsCurrent() { throw WirelessFailure.peerMismatch }
    try native.start(allowPermissionPrompt: allowPermissionPrompt)
  }

  func scan() { native.scan() }
  func stopScan() { native.stopScan() }
  func discardDiscoveries() { native.discardDiscoveries() }
  func disconnect(session: UUID) {
    registrationNotifications.pause(session: session)
    if geotagSubscription?.session == session { cancelGeotagSubscription() }
    native.disconnect(session: session)
  }

  func connect(peripheralID: UUID, session: UUID) {
    if var geotag = geotagSubscription {
      let decision = geotag.connect(peripheralID: peripheralID, session: session)
      geotagSubscription = geotag
      guard applyGeotagDecision(decision) else { return }
    }
    if let experiment {
      guard case .awaitingConnection = experiment.step, experiment.selectionIsCurrent(),
        experiment.ticket.authorizes(peripheralID: peripheralID, session: session)
      else { return reject(session: session) }
      self.experiment?.step = .awaitingModel(session)
    }
    registrationNotifications.requestedLink(peripheralID: peripheralID, session: session)
    native.connect(peripheralID: peripheralID, session: session)
  }

  func perform(_ action: BLEProtocolAction, session: UUID) {
    if var geotag = geotagSubscription {
      let decision = geotag.perform(action, session: session)
      geotagSubscription = geotag
      guard applyGeotagDecision(decision) else { return }
    }
    guard let experiment else { return native.perform(action, session: session) }
    guard experiment.step.session == session, experiment.selectionIsCurrent() else {
      return reject(session: session)
    }
    let statusKey = ProbeSecureStatusComparison.characteristic
    switch (experiment.step, action) {
    case (.awaitingRead, .read(statusKey)):
      self.experiment?.step = .awaitingStatus(session)
      native.perform(action, session: session)
    case (.awaitingAcknowledgement(_, let current), .write(statusKey, let payload, .authenticate)):
      var expected = current
      expected[expected.startIndex + 3] = 0x20
      guard payload == expected else { return reject(session: session) }
      self.experiment?.step = .acknowledged(session)
      acknowledgementUsed = true
      native.perform(.write(statusKey, experiment.ticket.acknowledgement(), .authenticate), session: session)
      observeAcknowledgement?()
    case (.acknowledged, .write(statusKey, _, _)):
      reject(session: session)
    case (.acknowledged, _):
      native.perform(action, session: session)
    default:
      reject(session: session)
    }
  }

  private func receive(_ event: BluetoothDriverEvent) {
    let occurredAt = Date()
    if var geotag = geotagSubscription {
      let decision = geotag.receive(event)
      geotagSubscription = geotag
      guard applyGeotagDecision(decision) else { return }
    }
    if let experiment {
      switch event {
      case .peerModel(let session, let model):
        guard case .awaitingModel(session) = experiment.step, experiment.selectionIsCurrent(),
          model.flatMap(WirelessCameraModel.init(bluetoothModelNumber:)) == .xt5
        else { return reject(session: session) }
        self.experiment?.step = .awaitingRead(session)
      case .protocolEvent(let session, let protocolEvent):
        guard experiment.step.session == session, experiment.selectionIsCurrent() else {
          return reject(session: session)
        }
        switch (experiment.step, protocolEvent) {
        case (.rejected, _):
          return
        case (.awaitingRead, .services), (_, .failed), (.acknowledged, _):
          break
        case (.awaitingStatus, .read(ProbeSecureStatusComparison.characteristic, let value)):
          // The production profile reports its usual malformed-read error.
          // Until the length is valid no write can pass this driver.
          if value.count == 4 { self.experiment?.step = .awaitingAcknowledgement(session, value) }
        default:
          return reject(session: session)
        }
      default:
        break
      }
    }
    eventHandler?(event)
    let observations = registrationNotifications.receive(event, at: occurredAt)
    if !observations.isEmpty {
      flushRegistrationNotifications?(observations)
    }
    if case .disconnected(let session, _) = event, geotagSubscription?.session == session {
      retireGeotagSubscription()
    }
  }

  private func applyGeotagDecision(_ decision: ProbeGeotagSubscription.Decision) -> Bool {
    switch decision {
    case .forward:
      return true
    case .ignore:
      break
    case .submit(let action, let session):
      native.perform(action, session: session)
    case .release(let held, let session):
      geotagSubscriptionAcknowledged = true
      native.perform(held, session: session)
    case .reject(let reason, let session):
      geotagSubscriptionFailure = reason
      cancelGeotagSubscription()
      eventHandler?(.linkFailed(session, reason.wirelessFailure))
    }
    return false
  }

  private func reject(session: UUID) {
    guard let experiment else { return }
    if case .rejected = experiment.step { return }
    let active = experiment.step.session ?? session
    self.experiment?.step = .rejected(active)
    eventHandler?(.linkFailed(active, .peerMismatch))
  }
}
