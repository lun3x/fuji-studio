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
    checkNotificationObservation()
    checkProductionRegistration()
    checkReconnectNotifications()
    checkImageViewingLaunch()

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

  static let geotagRequest = BLEGATTCharacteristic(
    service: "4c0020fe-f3b6-40de-acc9-77d129067b14",
    characteristic: "ad06c7b7-f41a-46f4-a29a-712055319122")

  static func checkProductionRegistration() {
    let pairing = ProfileTrial(intent: .pair)
    pairing.reachConfigurationAcknowledgement()
    precondition(pairing.native.actions.last == .subscribe(geotagRequest))
    precondition(!pairing.ready)
    pairing.emit(.subscribed(geotagRequest))
    pairing.finishLink()
    precondition(pairing.ready)

    let reconnect = ProfileTrial(intent: .reconnect)
    reconnect.reachConfigurationAcknowledgement()
    reconnect.finishLink()
    precondition(reconnect.ready)

    let subscriptions = pairing.native.actions.filter { if case .subscribe = $0 { true } else { false } }
    precondition(subscriptions == [
      .subscribe(ProfileTrial.readiness), .subscribe(ProfileTrial.secondIndication),
      .subscribe(ProfileTrial.configurationNotification), .subscribe(geotagRequest),
      .subscribe(ProfileTrial.networkName),
    ])
    precondition(pairing.native.actions.filter { $0 != .subscribe(geotagRequest) } == reconnect.native.actions)
    precondition(pairing.native.actions.filter {
      if case .write = $0 { return true }
      return false
    }.count == 2, "The probe submitted an extra characteristic value write")

    pairing.emit(.notification(geotagRequest, Data([0xde, 0xad])))
    precondition(pairing.flushed.isEmpty)
    pairing.native.eventHandler?(.disconnected(pairing.session, .connectionLost))
    precondition(pairing.flushed.map(\.message) == [
      "Registration notification: role=geotag-request length_class=1-2 timing=after-ready",
    ])
    print("Production X-T5 pairing and reconnect pass through the probe with deferred geotag observations.")
  }

  static func checkReconnectNotifications() {
    let baseline = ProfileTrial(intent: .reconnect)
    baseline.reachConfigurationAcknowledgement()
    baseline.finishLink()
    precondition(baseline.ready)

    let trial = ProfileTrial(intent: .reconnect, extraNotification: true)
    trial.reachConfigurationAcknowledgement()
    precondition(trial.native.actions.last == .subscribe(geotagRequest))
    precondition(!trial.native.actions.contains(.subscribe(ProfileTrial.networkName)))
    precondition(!trial.adapter.reconnectGeotagAcknowledged)
    let ackTrial = Experiment(requestRead: false)
    precondition(!ackTrial.adapter.beginReconnectNotifications(peripheralID: UUID()) { true })
    precondition(!trial.adapter.beginExperiment(ackTrial.ticket) { true })
    trial.emit(.subscribed(geotagRequest))
    trial.finishLink()
    precondition(trial.ready && trial.adapter.reconnectGeotagAcknowledged && trial.failures.isEmpty)
    var expected = baseline.native.actions
    expected.insert(.subscribe(geotagRequest), at: expected.firstIndex(of: .subscribe(ProfileTrial.networkName))!)
    precondition(trial.native.actions == expected)

    for event in [
      BLEProtocolEvent.subscriptionUnavailable(geotagRequest),
      .subscriptionUnavailable(ProfileTrial.networkName), .subscribed(ProfileTrial.networkName),
      .failed(geotagRequest, .unsupportedProtocol),
    ] {
      let stopped = ProfileTrial(intent: .reconnect, extraNotification: true)
      stopped.reachConfigurationAcknowledgement()
      let actions = stopped.native.actions
      stopped.emit(event)
      stopped.emit(.subscribed(geotagRequest))
      precondition(stopped.failures == [.unsupportedProtocol] && stopped.native.actions == actions)
      precondition(!stopped.ready && !stopped.adapter.reconnectGeotagAcknowledged)
    }

    let missing = ProfileTrial(intent: .reconnect, extraNotification: true, includeGeotag: false)
    precondition(missing.failures == [.unsupportedProtocol] && missing.native.actions.isEmpty)
    let wrongModel = ProfileTrial(intent: .reconnect, extraNotification: true, model: "X-E3")
    precondition(wrongModel.failures == [.peerMismatch] && wrongModel.native.actions.isEmpty)
    for staleSession in [false, true] {
      let rejected = ProfileTrial(intent: .reconnect, extraNotification: true)
      rejected.reachConfigurationAcknowledgement()
      let actions = rejected.native.actions
      if !staleSession { rejected.selectionIsCurrent = false }
      rejected.emit(.subscribed(geotagRequest), session: staleSession ? UUID() : rejected.session)
      precondition(rejected.failures == [.peerMismatch] && rejected.native.actions == actions)
    }
    let cancelled = ProfileTrial(intent: .reconnect, extraNotification: true)
    cancelled.reachConfigurationAcknowledgement()
    let actions = cancelled.native.actions
    cancelled.adapter.disconnect(session: cancelled.session)
    cancelled.emit(.subscribed(geotagRequest))
    precondition(cancelled.native.actions == actions && !cancelled.adapter.reconnectGeotagAcknowledged)
    print("Saved reconnect notification scope, exact action order, and rejection checks passed.")
  }

  static func checkImageViewingLaunch() {
    func activationTrial(extraNotification: Bool = false) -> ProfileTrial {
      let trial = ProfileTrial(intent: .reconnect, extraNotification: extraNotification)
      trial.reachConfigurationAcknowledgement()
      if extraNotification { trial.emit(.subscribed(geotagRequest)) }
      trial.finishLink()
      return trial
    }
    let launch = ProbeImageViewingLaunch.launch
    let password = ProbeImageViewingLaunch.password
    let standard = BLEProtocolAction.write(launch, Data([0x04, 0x00]), .activateWiFi)
    let alternative = BLEProtocolAction.write(launch, Data([0x03, 0x00]), .activateWiFi)
    let baseline = activationTrial(extraNotification: true)
    let trial = activationTrial(extraNotification: true)
    precondition(baseline.adapter.reconnectGeotagAcknowledged && trial.adapter.reconnectGeotagAcknowledged)
    precondition(!trial.adapter.beginImageViewing(peripheralID: UUID()) { true })
    precondition(!trial.adapter.beginImageViewing(peripheralID: trial.peer) { false })
    precondition(trial.beginImageViewing())
    precondition(!trial.beginImageViewing())
    let ackTrial = Experiment(requestRead: false)
    precondition(!trial.adapter.beginExperiment(ackTrial.ticket) { true })

    for (activated, expected) in [(baseline, standard), (trial, alternative)] {
      let initialActionCount = activated.native.actions.count
      activated.advance(.activateWiFi)
      activated.emit(.read(password, Data("synthetic".utf8)))
      precondition(Array(activated.native.actions.dropFirst(initialActionCount)) == [.read(password), expected])
      activated.emit(.wrote(launch))
      activated.emit(.notification(ProfileTrial.readiness, Data([0xff])))
      precondition(!activated.wifiReady, "A launch callback or unknown status reported readiness")
      activated.emit(.notification(ProfileTrial.readiness, Data([0x01])))
      precondition(activated.wifiReady && activated.failures.isEmpty)
    }
    precondition(trial.adapter.imageViewLaunchUsed && !baseline.adapter.imageViewLaunchUsed)
    trial.adapter.perform(standard, session: trial.session)
    precondition(trial.failures == [.unsupportedProtocol] && trial.native.actions.last == alternative)

    let invalidActions: [BLEProtocolAction] = [
      .write(launch, Data([0x04]), .activateWiFi),
      .write(launch, Data([0x04, 0x00]), .identify),
      .write(password, Data([0x04, 0x00]), .activateWiFi),
      .read(password),
    ]
    for action in invalidActions {
      let rejected = activationTrial()
      precondition(rejected.beginImageViewing())
      rejected.advance(.activateWiFi)
      rejected.adapter.eventHandler = { [weak rejected] event in
        if case .linkFailed(_, let failure) = event { rejected?.failures.append(failure) }
      }
      rejected.emit(.read(password, Data("synthetic".utf8)))
      rejected.adapter.perform(action, session: rejected.session)
      precondition(rejected.failures == [.unsupportedProtocol])
      precondition(!rejected.adapter.imageViewLaunchUsed && rejected.native.actions.last == .read(password))
    }

    for staleSession in [false, true] {
      let rejected = activationTrial()
      precondition(rejected.beginImageViewing())
      rejected.advance(.activateWiFi)
      if !staleSession { rejected.selectionIsCurrent = false }
      rejected.emit(.read(password, Data("synthetic".utf8)), session: staleSession ? UUID() : rejected.session)
      precondition(rejected.failures == [.peerMismatch] && !rejected.adapter.imageViewLaunchUsed)
      precondition(rejected.native.actions.last == .read(password))
    }
    let cancelled = activationTrial()
    precondition(cancelled.beginImageViewing())
    cancelled.advance(.activateWiFi)
    cancelled.adapter.disconnect(session: cancelled.session)
    cancelled.emit(.read(password, Data("synthetic".utf8)))
    precondition(!cancelled.adapter.imageViewLaunchUsed && cancelled.native.actions.last == .read(password))
    precondition(!cancelled.beginImageViewing())
    print("Image-viewing single launch, production readiness, and rejected action checks passed.")
  }

  @MainActor
  final class ProfileTrial {
    private static let status = ProbeSecureStatusComparison.characteristic
    private static let identify = BLEGATTCharacteristic(
      service: status.service, characteristic: "85b9163e-62d1-49ff-a6f5-054b4630d4a1")
    static let readiness = BLEGATTCharacteristic(
      service: geotagRequest.service, characteristic: "a68e3f66-0fcc-4395-8d4c-aa980b5877fa")
    static let secondIndication = BLEGATTCharacteristic(
      service: geotagRequest.service, characteristic: "bd17ba04-b76b-4892-a545-b73ba1f74dae")
    static let configurationNotification = BLEGATTCharacteristic(
      service: geotagRequest.service, characteristic: "f9150137-5d40-4801-a8dc-f7fc5b01da50")
    static let networkName = BLEGATTCharacteristic(
      service: "4e941240-d01d-46b9-a5ea-67636806830b", characteristic: "bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4")
    private static let firmware = BLEGATTCharacteristic(service: "180a", characteristic: "2a26")

    let native = TestDriver()
    let adapter: ProbeRegistrationBluetoothDriver
    let session = UUID()
    let peer = UUID()
    private var profile: XT5BLEProfile
    var selectionIsCurrent = true
    var failures: [WirelessFailure] = []
    private(set) var ready = false
    private(set) var wifiReady = false
    private(set) var flushed: [ProbeRegistrationNotificationEntry] = []

    init(
      intent: XT5BLEProfile.Intent, extraNotification: Bool = false,
      includeGeotag: Bool = true, model: String = "FF220001"
    ) {
      profile = XT5BLEProfile(intent: intent)
      adapter = ProbeRegistrationBluetoothDriver(native: native)
      adapter.eventHandler = { [weak self] event in self?.receive(event) }
      adapter.flushRegistrationNotifications = { [weak self] entries in self?.flushed.append(contentsOf: entries) }
      adapter.beginRegistrationObservation(peripheralID: peer)
      if extraNotification {
        precondition(adapter.beginReconnectNotifications(peripheralID: peer) { [weak self] in
          self?.selectionIsCurrent == true
        })
      }
      adapter.connect(peripheralID: peer, session: session)
      native.eventHandler?(.peerModel(session, model))
      var services: Set = [
        Self.status, Self.identify, Self.readiness, Self.secondIndication,
        Self.configurationNotification, Self.networkName, Self.firmware,
        ProbeImageViewingLaunch.password, ProbeImageViewingLaunch.launch,
      ]
      if includeGeotag { services.insert(geotagRequest) }
      emit(.services(services))
    }

    func beginImageViewing() -> Bool {
      adapter.beginImageViewing(peripheralID: peer) { [weak self] in self?.selectionIsCurrent == true }
    }

    func emit(_ event: BLEProtocolEvent, session: UUID? = nil) {
      native.eventHandler?(.protocolEvent(session ?? self.session, event))
    }

    func reachConfigurationAcknowledgement() {
      emit(.read(Self.status, Data([1, 2, 3, 4])))
      emit(.wrote(Self.status))
      emit(.wrote(Self.identify))
      emit(.read(Self.networkName, Data("synthetic".utf8)))
      emit(.subscribed(Self.readiness))
      emit(.subscribed(Self.secondIndication))
      emit(.subscribed(Self.configurationNotification))
    }

    func finishLink() {
      emit(.subscribed(Self.networkName))
      emit(.read(Self.firmware, Data("4.32".utf8)))
    }

    private func receive(_ event: BluetoothDriverEvent) {
      if case .linkFailed(let session, let failure) = event {
        precondition(self.session == session)
        failures.append(failure)
      }
      guard case .protocolEvent(let session, let event) = event else { return }
      precondition(self.session == session)
      advance(event)
    }

    func advance(_ event: BLEProtocolEvent) {
      for action in try! profile.receive(event) {
        if case .authenticated = action {
          ready = true
          adapter.endReconnectNotifications()
          adapter.markRegistrationObservationReady(peripheralID: peer)
        } else if case .wifiReady = action {
          wifiReady = true
        } else {
          adapter.perform(action, session: session)
        }
      }
    }
  }

  static func checkNotificationObservation() {
    let native = TestDriver()
    let adapter = ProbeRegistrationBluetoothDriver(native: native)
    let peer = UUID()
    let session = UUID()
    let otherSession = UUID()
    let known = BLEGATTCharacteristic(
      service: "4c0020fe-f3b6-40de-acc9-77d129067b14",
      characteristic: "f9150137-5d40-4801-a8dc-f7fc5b01da50")
    let unknown = BLEGATTCharacteristic(
      service: "180a", characteristic: known.characteristic)
    let bytes = Data([0xde, 0xad])
    var order: [String] = []
    var forwarded: [(UUID, BLEGATTCharacteristic, Data)] = []
    var flushed: [[ProbeRegistrationNotificationEntry]] = []
    adapter.eventHandler = { event in
      if case .disconnected = event { order.append("terminal") }
      guard case .protocolEvent(let id, .notification(let key, let data)) = event else { return }
      forwarded.append((id, key, data))
      order.append("forward")
      adapter.perform(.read(known), session: id)
      precondition(native.actions.last == .read(known))
      order.append("action")
    }
    adapter.flushRegistrationNotifications = { entries in
      order.append("flush")
      flushed.append(entries)
    }
    func emit(_ id: UUID, key: BLEGATTCharacteristic = known) {
      native.eventHandler?(.protocolEvent(id, .notification(key, bytes)))
    }

    adapter.beginRegistrationObservation(peripheralID: peer)
    adapter.connect(peripheralID: UUID(), session: otherSession)
    native.eventHandler?(.peerModel(otherSession, "X-T5"))
    emit(otherSession)
    adapter.connect(peripheralID: peer, session: session)
    emit(session)
    native.eventHandler?(.peerModel(session, "X-E3"))
    emit(session)
    native.eventHandler?(.peerModel(session, "FF220001"))
    emit(otherSession)
    emit(session, key: unknown)
    precondition(order == Array(repeating: ["forward", "action"], count: 5).flatMap { $0 })

    order.removeAll()
    let firstStart = Date()
    emit(session)
    let firstEnd = Date()
    guard order == ["forward", "action"] else {
      print("FAIL: notification reached the trace sink during an active link")
      exit(1)
    }
    order.removeAll()
    adapter.markRegistrationObservationReady(peripheralID: peer)
    let secondStart = Date()
    emit(session)
    let secondEnd = Date()
    precondition(order == ["forward", "action"] && flushed.isEmpty)
    native.eventHandler?(.disconnected(otherSession, .connectionLost))
    native.eventHandler?(.linkFailed(session, .connectionLost))
    adapter.disconnect(session: session)
    precondition(flushed.isEmpty, "A failure or pending disconnect flushed an active link")
    order.removeAll()
    native.eventHandler?(.disconnected(session, .connectionLost))
    precondition(order == ["terminal", "flush"] && flushed.count == 1)
    let entries = flushed[0]
    precondition(entries.map(\.message) == [
      "Registration notification: role=configuration length_class=1-2 timing=before-ready",
      "Registration notification: role=configuration length_class=1-2 timing=after-ready",
    ])
    precondition((firstStart...firstEnd).contains(entries[0].timestamp))
    precondition((secondStart...secondEnd).contains(entries[1].timestamp))
    native.eventHandler?(.disconnected(session, .connectionLost))
    precondition(flushed.count == 1, "Duplicate terminal callback flushed twice")
    order.removeAll()
    emit(session)
    precondition(order == ["forward", "action"])
    precondition(forwarded.count == 8 && forwarded.allSatisfy { $0.2 == bytes })
    precondition(forwarded[3].0 == otherSession && forwarded[4].1 == unknown)
    precondition(native.actions.count == forwarded.count)

    let nextSession = UUID()
    adapter.beginRegistrationObservation(peripheralID: peer)
    adapter.connect(peripheralID: peer, session: nextSession)
    native.eventHandler?(.peerModel(nextSession, "X-T5"))
    emit(nextSession, key: geotagRequest)
    for _ in 0..<80 { emit(nextSession) }
    precondition(flushed.count == 1, "Notification burst reached the sink before retirement")
    native.eventHandler?(.disconnected(nextSession, .connectionLost))
    precondition(flushed.count == 2)
    let truncated = flushed[1]
    precondition(truncated.count == 65 && truncated.last?.message == "Registration notifications truncated")
    precondition(truncated.first?.message ==
      "Registration notification: role=geotag-request length_class=1-2 timing=before-ready")
    precondition(zip(truncated, truncated.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp })
    print("Registration notification forwarding, deferred flush, timestamp, and bound checks passed.")
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
    let ticket: ProbeSecureStatusComparison.RegistrationTicket
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
      ticket = comparison.takeRegistrationTicket()!
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
