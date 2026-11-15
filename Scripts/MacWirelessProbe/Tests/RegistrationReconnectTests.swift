import Foundation
import FujiCameraCore

@main
@MainActor
private struct RegistrationReconnectTests {
  static let statusKey = ProbeSecureStatusComparison.characteristic
  static let original = Data([1, 2, 3, 0x82])
  static let current = Data([1, 2, 9, 0])
  static let normalAcknowledgement = BLEProtocolAction.write(
    statusKey, Data([1, 2, 9, 0x20]), .authenticate)

  static func main() {
    checkEligibility()

    let normal = TestDriver()
    let normalAdapter = ProbeRegistrationBluetoothDriver(native: normal)
    normalAdapter.perform(normalAcknowledgement, session: UUID())
    precondition(normal.actions == [normalAcknowledgement], "Unarmed reconnect was modified")

    let valid = Experiment()
    valid.receiveStatus(current)
    valid.adapter.perform(normalAcknowledgement, session: valid.session)
    precondition(valid.native.actions == [
      .read(statusKey), .write(statusKey, Data([1, 2, 3, 0xA2]), .authenticate),
    ])
    precondition(valid.adapter.acknowledgementUsed && valid.failures.isEmpty)
    let identify = BLEProtocolAction.write(
      .init(service: statusKey.service, characteristic: "85b9163e-62d1-49ff-a6f5-054b4630d4a1"),
      Data("synthetic".utf8), .identify)
    valid.adapter.perform(identify, session: valid.session)
    precondition(valid.native.actions.last == identify)
    valid.adapter.perform(normalAcknowledgement, session: valid.session)
    precondition(valid.native.actions.count == 3 && valid.failures == [valid.session])

    let wrongSession = Experiment()
    wrongSession.receiveStatus(current)
    wrongSession.adapter.perform(normalAcknowledgement, session: UUID())
    wrongSession.expectNoWrite()

    let revoked = Experiment()
    revoked.receiveStatus(current)
    revoked.selectionIsCurrent = false
    revoked.adapter.perform(normalAcknowledgement, session: revoked.session)
    revoked.expectNoWrite()

    let wrongPayload = Experiment()
    wrongPayload.receiveStatus(current)
    wrongPayload.adapter.perform(.write(statusKey, Data([1, 2, 7, 0x20]), .authenticate),
      session: wrongPayload.session)
    wrongPayload.expectNoWrite()

    let invalidLength = Experiment()
    invalidLength.receiveStatus(Data([1, 2, 3]))
    invalidLength.adapter.perform(normalAcknowledgement, session: invalidLength.session)
    invalidLength.expectNoWrite()

    let wrongModel = Experiment(model: "X-E3")
    wrongModel.adapter.perform(normalAcknowledgement, session: wrongModel.session)
    precondition(wrongModel.native.actions.isEmpty && wrongModel.failures == [wrongModel.session])

    let wrongPeer = Experiment(connectToOtherPeer: true)
    precondition(wrongPeer.native.connections == 0 && wrongPeer.native.actions.isEmpty)
    precondition(wrongPeer.failures == [wrongPeer.session])

    let wrongAction = Experiment(requestRead: false)
    wrongAction.adapter.perform(.read(.init(service: statusKey.service, characteristic: "2a26")),
      session: wrongAction.session)
    precondition(wrongAction.native.actions.isEmpty && wrongAction.failures == [wrongAction.session])
    print("Registration reconnect eligibility, scoped substitution, and rejection checks passed.")
  }

  static func checkEligibility() {
    let peer = UUID()
    let cameraID = WirelessCameraID()
    var eligibility = makeComparison(peer: peer, cameraID: cameraID)
    let failedSession = UUID()
    func stage(_ comparison: inout ProbeSecureStatusComparison, _ value: Data) {
      comparison.begin(.reconnect, peripheralID: peer, cameraID: cameraID)
      comparison.verifyXT5(session: failedSession)
      precondition(comparison.receive(.read(statusKey, value), session: failedSession))
    }
    stage(&eligibility, current)
    eligibility.endAttempt()
    precondition(eligibility.takeRegistrationTicket() == nil)
    stage(&eligibility, Data([1, 2, 3, 0x91]))
    eligibility.finishFailedReconnect()
    precondition(eligibility.takeRegistrationTicket() == nil)
    stage(&eligibility, current)
    eligibility.finishFailedReconnect()
    let ticketForOtherRecord = eligibility.takeRegistrationTicket()
    precondition(ticketForOtherRecord?.matches(peripheralID: peer, cameraID: .init()) == false)
    precondition(eligibility.takeRegistrationTicket() == nil)
    stage(&eligibility, current)
    eligibility.finishFailedReconnect()
    let ticket = eligibility.takeRegistrationTicket()
    precondition(ticket?.matches(peripheralID: peer, cameraID: cameraID) == true)
    precondition(ticket != nil && ticket?.authorizes(peripheralID: peer, session: failedSession) == false)
    precondition(eligibility.takeRegistrationTicket() == nil)
    stage(&eligibility, current)
    eligibility.finishFailedReconnect()
    eligibility.begin(.pairing, peripheralID: peer)
    precondition(eligibility.takeRegistrationTicket() == nil)
  }

  static func makeComparison(peer: UUID, cameraID: WirelessCameraID) -> ProbeSecureStatusComparison {
    var comparison = ProbeSecureStatusComparison()
    let session = UUID()
    comparison.begin(.pairing, peripheralID: peer)
    comparison.verifyXT5(session: session)
    precondition(comparison.receive(.read(statusKey, original), session: session))
    precondition(comparison.commitPairing(peripheralID: peer, cameraID: cameraID))
    return comparison
  }

  @MainActor
  final class Experiment {
    let native = TestDriver()
    let adapter: ProbeRegistrationBluetoothDriver
    let session = UUID()
    var selectionIsCurrent = true
    var failures: [UUID] = []

    init(model: String = "FF220001", connectToOtherPeer: Bool = false, requestRead: Bool = true) {
      adapter = ProbeRegistrationBluetoothDriver(native: native)
      let peer = UUID()
      let cameraID = WirelessCameraID()
      var comparison = makeComparison(peer: peer, cameraID: cameraID)
      let failedSession = UUID()
      comparison.begin(.reconnect, peripheralID: peer, cameraID: cameraID)
      comparison.verifyXT5(session: failedSession)
      precondition(comparison.receive(.read(statusKey, current), session: failedSession))
      comparison.finishFailedReconnect()
      let ticket = comparison.takeRegistrationTicket()!
      adapter.eventHandler = { [weak self] event in
        if case .linkFailed(let id, _) = event { self?.failures.append(id) }
      }
      adapter.beginExperiment(ticket) { [weak self] in self?.selectionIsCurrent == true }
      adapter.connect(peripheralID: connectToOtherPeer ? UUID() : peer, session: session)
      if !connectToOtherPeer {
        native.eventHandler?(.peerModel(session, model))
        if requestRead { adapter.perform(.read(statusKey), session: session) }
      }
    }

    func receiveStatus(_ value: Data) {
      native.eventHandler?(.protocolEvent(session, .read(statusKey, value)))
    }

    func expectNoWrite() {
      precondition(native.actions == [.read(statusKey)])
      precondition(!adapter.acknowledgementUsed && failures == [session])
    }
  }
}

@MainActor
private final class TestDriver: BluetoothPeripheralDriver {
  var eventHandler: ((BluetoothDriverEvent) -> Void)?
  var actions: [BLEProtocolAction] = []
  var connections = 0

  func start(allowPermissionPrompt: Bool) throws {}
  func scan() {}
  func stopScan() {}
  func discardDiscoveries() {}
  func disconnect(session: UUID) {}
  func connect(peripheralID: UUID, session: UUID) { connections += 1 }
  func perform(_ action: BLEProtocolAction, session: UUID) { actions.append(action) }
}
