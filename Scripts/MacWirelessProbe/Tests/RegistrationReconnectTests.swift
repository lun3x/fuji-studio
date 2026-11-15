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
    checkGeotagSubscription()

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

  static func checkGeotagSubscription() {
    let geo = ProbeGeotagSubscription.characteristic
    let registration = Experiment(requestRead: false)
    precondition(!registration.adapter.beginGeotagSubscription(peripheralID: UUID()))
    let normal = GeotagTrial(extraSubscription: false)
    normal.reachConfigurationAcknowledgement()
    normal.finishPairing()
    precondition(normal.ready && !normal.adapter.geotagSubscriptionAcknowledged)

    let included = GeotagTrial()
    precondition(!included.adapter.beginExperiment(registration.ticket) { true })
    included.reachConfigurationAcknowledgement()
    precondition(included.native.actions.last == .subscribe(geo))
    precondition(!included.native.actions.contains(.subscribe(ProbeGeotagSubscription.networkName)))
    precondition(!included.adapter.geotagSubscriptionAcknowledged)
    included.emit(.subscribed(geo))
    precondition(included.adapter.geotagSubscriptionAcknowledged)
    included.finishPairing()
    var expected = normal.native.actions
    let next = expected.firstIndex(of: .subscribe(ProbeGeotagSubscription.networkName))!
    expected.insert(.subscribe(geo), at: next)
    precondition(included.ready && included.native.actions == expected)
    precondition(included.hasSameForwardedEvents(as: normal), "An original profile event changed")
    precondition(normal.native.actions.filter {
      if case .write = $0 { return true }
      return false
    }.count == 2, "An extra value write reached the driver")
    included.emit(.subscribed(geo))
    precondition(included.native.actions == expected && included.failures == [included.session])

    let missing = GeotagTrial(includeCharacteristic: false)
    missing.expectRejected(.geotagCharacteristicMissing, nativeActionCount: 0)
    let wrongPeer = GeotagTrial(connectRequestedPeer: false)
    wrongPeer.expectRejected(.geotagUnexpectedPeer, nativeActionCount: 0)
    precondition(wrongPeer.native.connections == 0)
    let wrongModel = GeotagTrial(model: "X-E3")
    wrongModel.expectRejected(.geotagUnexpectedPeer, nativeActionCount: 0)

    let unsupported = GeotagTrial()
    unsupported.reachConfigurationAcknowledgement()
    let heldCount = unsupported.native.actions.count
    unsupported.emit(.subscriptionUnavailable(geo))
    unsupported.expectRejected(.geotagSubscriptionUnsupported, nativeActionCount: heldCount)

    let failure = GeotagTrial()
    failure.reachConfigurationAcknowledgement()
    failure.emit(.failed(geo, .authentication))
    failure.expectRejected(.geotagSubscriptionFailed, nativeActionCount: heldCount)

    let stale = GeotagTrial()
    stale.reachConfigurationAcknowledgement()
    stale.emit(.subscribed(geo), session: UUID())
    stale.emit(.subscribed(geo))
    stale.expectRejected(.geotagUnexpectedPeer, nativeActionCount: heldCount)

    let unexpected = GeotagTrial()
    unexpected.reachConfigurationAcknowledgement()
    unexpected.emit(.subscribed(ProbeGeotagSubscription.networkName))
    unexpected.expectRejected(.geotagUnexpectedSequence, nativeActionCount: heldCount)

    let skipped = GeotagTrial(includeFirmware: false)
    skipped.reachConfigurationAcknowledgement()
    skipped.emit(.subscriptionUnavailable(ProbeGeotagSubscription.networkName))
    guard !skipped.ready else {
      print("FAIL: network-name skip completed the profile without a geotag acknowledgment")
      exit(1)
    }
    skipped.expectRejected(.geotagUnexpectedSequence, nativeActionCount: heldCount)

    let cancelled = GeotagTrial()
    cancelled.reachConfigurationAcknowledgement()
    cancelled.adapter.cancelGeotagSubscription()
    cancelled.adapter.disconnect(session: cancelled.session)
    cancelled.emit(.subscribed(geo))
    precondition(cancelled.native.actions.count == heldCount)
    precondition(!cancelled.adapter.geotagSubscriptionAcknowledged && cancelled.failures.isEmpty)
    print("Geotag subscription order, unchanged standard path, and rejection checks passed.")
  }

  @MainActor
  final class GeotagTrial {
    private enum Forwarded: Equatable {
      case services(Set<BLEGATTCharacteristic>)
      case read(BLEGATTCharacteristic, Data)
      case wrote(BLEGATTCharacteristic)
      case subscribed(BLEGATTCharacteristic)
      case subscriptionUnavailable(BLEGATTCharacteristic)
    }

    private static let status = ProbeSecureStatusComparison.characteristic
    private static let identify = BLEGATTCharacteristic(
      service: status.service, characteristic: "85b9163e-62d1-49ff-a6f5-054b4630d4a1")
    private static let readiness = BLEGATTCharacteristic(
      service: ProbeGeotagSubscription.configurationNotification.service,
      characteristic: "a68e3f66-0fcc-4395-8d4c-aa980b5877fa")
    private static let second = BLEGATTCharacteristic(
      service: readiness.service, characteristic: "bd17ba04-b76b-4892-a545-b73ba1f74dae")
    private static let firmware = BLEGATTCharacteristic(service: "180a", characteristic: "2a26")

    let native = TestDriver()
    let adapter: ProbeRegistrationBluetoothDriver
    let session = UUID()
    private var profile = XT5BLEProfile()
    private var events: [Forwarded] = []
    private(set) var ready = false
    private(set) var failures: [UUID] = []

    init(
      extraSubscription: Bool = true, includeCharacteristic: Bool = true,
      connectRequestedPeer: Bool = true, model: String = "FF220001", includeFirmware: Bool = true
    ) {
      adapter = ProbeRegistrationBluetoothDriver(native: native)
      adapter.eventHandler = { [weak self] event in self?.receive(event) }
      let peer = UUID()
      if extraSubscription { precondition(adapter.beginGeotagSubscription(peripheralID: peer)) }
      adapter.connect(peripheralID: connectRequestedPeer ? peer : UUID(), session: session)
      native.eventHandler?(.peerModel(session, model))
      var keys: Set = [
        Self.status, Self.identify, Self.readiness, Self.second,
        ProbeGeotagSubscription.configurationNotification, ProbeGeotagSubscription.networkName,
      ]
      if includeFirmware { keys.insert(Self.firmware) }
      if includeCharacteristic { keys.insert(ProbeGeotagSubscription.characteristic) }
      emit(.services(keys))
    }

    func emit(_ event: BLEProtocolEvent, session: UUID? = nil) {
      native.eventHandler?(.protocolEvent(session ?? self.session, event))
    }

    func reachConfigurationAcknowledgement() {
      emit(.read(Self.status, Data([1, 2, 3, 4])))
      emit(.wrote(Self.status))
      emit(.wrote(Self.identify))
      emit(.read(ProbeGeotagSubscription.networkName, Data("synthetic".utf8)))
      emit(.subscribed(Self.readiness))
      emit(.subscribed(Self.second))
      emit(.subscribed(ProbeGeotagSubscription.configurationNotification))
    }

    func finishPairing() {
      emit(.subscribed(ProbeGeotagSubscription.networkName))
      emit(.read(Self.firmware, Data("4.32".utf8)))
    }

    func hasSameForwardedEvents(as other: GeotagTrial) -> Bool { events == other.events }

    func expectRejected(_ reason: ProbeGeotagSubscription.Failure, nativeActionCount: Int) {
      precondition(adapter.geotagSubscriptionFailure == reason && failures == [session])
      precondition(native.actions.count == nativeActionCount && !adapter.geotagSubscriptionAcknowledged)
    }

    private func receive(_ event: BluetoothDriverEvent) {
      if case .linkFailed(let session, _) = event { failures.append(session) }
      guard case .protocolEvent(let session, let event) = event else { return }
      precondition(self.session == session)
      switch event {
      case .services(let keys): events.append(.services(keys))
      case .read(let key, let data): events.append(.read(key, data))
      case .wrote(let key): events.append(.wrote(key))
      case .subscribed(let key): events.append(.subscribed(key))
      case .subscriptionUnavailable(let key): events.append(.subscriptionUnavailable(key))
      default: preconditionFailure("Unexpected event reached the production profile")
      }
      for action in try! profile.receive(event) {
        if case .authenticated = action {
          ready = true
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
    emit(nextSession, key: ProbeGeotagSubscription.characteristic)
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
