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
  private(set) var acknowledgementUsed = false
  var eventHandler: ((BluetoothDriverEvent) -> Void)?
  var observeAcknowledgement: (() -> Void)?

  init(native: any BluetoothPeripheralDriver) {
    self.native = native
    native.eventHandler = { [weak self] event in self?.receive(event) }
  }

  func beginExperiment(
    _ ticket: ProbeSecureStatusComparison.RegistrationTicket, selectionIsCurrent: @escaping () -> Bool
  ) {
    experiment = Experiment(ticket: ticket, selectionIsCurrent: selectionIsCurrent)
  }

  func endExperiment() { experiment = nil }
  func resetObservation() { acknowledgementUsed = false }

  func start(allowPermissionPrompt: Bool) throws {
    if let experiment, !experiment.selectionIsCurrent() { throw WirelessFailure.peerMismatch }
    try native.start(allowPermissionPrompt: allowPermissionPrompt)
  }

  func scan() { native.scan() }
  func stopScan() { native.stopScan() }
  func discardDiscoveries() { native.discardDiscoveries() }
  func disconnect(session: UUID) { native.disconnect(session: session) }

  func connect(peripheralID: UUID, session: UUID) {
    if let experiment {
      guard case .awaitingConnection = experiment.step, experiment.selectionIsCurrent(),
        experiment.ticket.authorizes(peripheralID: peripheralID, session: session)
      else { return reject(session: session) }
      self.experiment?.step = .awaitingModel(session)
    }
    native.connect(peripheralID: peripheralID, session: session)
  }

  func perform(_ action: BLEProtocolAction, session: UUID) {
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
  }

  private func reject(session: UUID) {
    guard let experiment else { return }
    if case .rejected = experiment.step { return }
    let active = experiment.step.session ?? session
    self.experiment?.step = .rejected(active)
    eventHandler?(.linkFailed(active, .peerMismatch))
  }
}
