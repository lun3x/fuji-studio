import Foundation
import FujiCameraCore
import Testing
@testable import FujiStudio

@MainActor
struct ManualWiFiBluetoothDriverTests {
  private let identification = BLEGATTCharacteristic(
    service: "123d8f06-62a1-4935-9322-833c531ee225",
    characteristic: "85b9163e-62d1-49ff-a6f5-054b4630d4a1")

  @Test func onlyReplacesExactIdentityWriteOnVerifiedCurrentXT5Link() {
    let native = Driver()
    let driver = ManualWiFiBluetoothDriver(native: native)
    let original = BLEProtocolAction.write(identification, Data("Fuji Studio".utf8), .identify)
    let otherBytes = BLEProtocolAction.write(identification, Data("Other".utf8), .identify)
    let otherPurpose = BLEProtocolAction.write(identification, Data("Fuji Studio".utf8), .authenticate)
    let otherService = BLEProtocolAction.write(
      BLEGATTCharacteristic(service: "91f1de68-dff6-466e-8b65-ff13b0f16fb8",
        characteristic: "85b9163e-62d1-49ff-a6f5-054b4630d4a1"),
      Data("Fuji Studio".utf8), .identify)
    let oldSession = UUID()
    let currentSession = UUID()
    driver.connect(peripheralID: UUID(), session: oldSession)
    native.eventHandler?(.peerModel(oldSession, "X-T5"))
    driver.connect(peripheralID: UUID(), session: currentSession)
    driver.perform(original, session: oldSession)
    native.eventHandler?(.peerModel(oldSession, "X-T5"))
    driver.perform(original, session: currentSession)
    native.eventHandler?(.peerModel(currentSession, "X-E3"))
    driver.perform(original, session: currentSession)

    native.eventHandler?(.peerModel(currentSession, "FF220001"))
    driver.perform(otherBytes, session: currentSession)
    driver.perform(otherPurpose, session: currentSession)
    driver.perform(otherService, session: currentSession)
    driver.perform(original, session: currentSession)
    driver.disconnect(session: currentSession)
    driver.perform(original, session: currentSession)

    #expect(native.actions == [
      original, original, otherBytes, otherPurpose, otherService,
      .write(identification, Data("Fuji iPhone".utf8), .identify)
    ])
  }

  @Test(arguments: [false, true]) func onlyAdvancesIdentityAfterBothReferenceAppFlagsAreAcknowledged(fails: Bool) {
    let native = Driver()
    var recorded: [ManualWiFiBluetoothTrace.Event] = []
    let driver = ManualWiFiBluetoothDriver(
      native: native, trace: { _, event in recorded.append(event) }, writesReferenceAppFlags: true)
    let flags = [
      BLEGATTCharacteristic(service: "1111", characteristic: "caedb497-83bf-482c-91ef-91cf6f1216ff"),
      BLEGATTCharacteristic(service: "2222", characteristic: "98934b2c-756c-4632-aa2f-dcba1bfec824"),
    ]
    let session = UUID()
    var acknowledgments: [BLEGATTCharacteristic] = []
    driver.eventHandler = { event in
      if case .protocolEvent(session, .wrote(let characteristic)) = event {
        acknowledgments.append(characteristic)
      }
    }
    driver.connect(peripheralID: UUID(), session: session)
    native.eventHandler?(.peerModel(session, "X-T5"))
    native.eventHandler?(.protocolEvent(session, .services(Set(flags + [identification]))))
    driver.perform(.write(identification, Data("Fuji Studio".utf8), .identify), session: session)
    native.eventHandler?(.protocolEvent(session, .wrote(identification)))
    native.eventHandler?(.protocolEvent(UUID(), .wrote(flags[0])))
    #expect(native.actions == [
      .write(identification, Data("Fuji iPhone".utf8), .identify), .write(flags[0], Data([1]), .identify),
    ])
    native.eventHandler?(.protocolEvent(session, .wrote(flags[0])))
    #expect(native.actions.last == .write(flags[1], Data([1]), .identify))
    #expect(acknowledgments.isEmpty)
    if fails {
      native.eventHandler?(.protocolEvent(session, .failed(flags[1], .unsupportedProtocol)))
      #expect(acknowledgments.isEmpty)
      #expect(recorded.contains(.appFlagFailed(ordinal: 2, .init(WirelessFailure.unsupportedProtocol))))
    } else {
      native.eventHandler?(.protocolEvent(session, .wrote(flags[1])))
      #expect(acknowledgments == [identification])
      #expect(recorded.suffix(4) == [
        .appFlagSubmitted(ordinal: 1), .appFlagAcknowledged(ordinal: 1),
        .appFlagSubmitted(ordinal: 2), .appFlagAcknowledged(ordinal: 2),
      ])
    }
  }

  @Test func submitsImageViewingOnlyForTheOrderedSelectedSession() throws {
    let native = Driver()
    let driver = ManualWiFiBluetoothDriver(native: native)
    let peripheral = UUID()
    let session = UUID()
    let password = BLEProtocolAction.read(ProbeImageViewingLaunch.password)
    let standard = BLEProtocolAction.write(
      ProbeImageViewingLaunch.launch, Data([0x04, 0x00]), .activateWiFi)
    driver.connect(peripheralID: peripheral, session: session)
    native.eventHandler?(.peerModel(session, "X-T5"))
    try driver.beginImageViewingActivation(peripheralID: peripheral) { true }
    driver.perform(password, session: session)
    native.eventHandler?(.protocolEvent(UUID(), .read(ProbeImageViewingLaunch.password, Data())))
    #expect(native.actions == [password])
    native.eventHandler?(.protocolEvent(session, .read(ProbeImageViewingLaunch.password, Data())))
    driver.perform(standard, session: UUID())
    driver.perform(standard, session: session)
    #expect(native.actions == [password, .write(ProbeImageViewingLaunch.launch, Data([3, 0]), .activateWiFi)])

    driver.disconnect(session: session)
    driver.perform(standard, session: session)
    #expect(native.actions == [password, .write(ProbeImageViewingLaunch.launch, Data([3, 0]), .activateWiFi)])
  }

  @Test(arguments: [false, true]) func rejectsActivationWithoutCurrentOrderedHandshake(selectionExpires: Bool) throws {
    let native = Driver()
    let driver = ManualWiFiBluetoothDriver(native: native)
    let peripheral = UUID()
    let session = UUID()
    let password = BLEProtocolAction.read(ProbeImageViewingLaunch.password)
    var current = true
    driver.connect(peripheralID: peripheral, session: session)
    native.eventHandler?(.peerModel(session, "X-T5"))
    try driver.beginImageViewingActivation(peripheralID: peripheral) { current }
    driver.perform(password, session: session)
    if selectionExpires {
      native.eventHandler?(.protocolEvent(session, .read(ProbeImageViewingLaunch.password, Data())))
      current = false
    }
    driver.perform(.write(ProbeImageViewingLaunch.launch, Data([0x04, 0x00]), .activateWiFi), session: session)
    #expect(native.actions == [password])
  }

  @Test(arguments: [false, true]) func tracesActivationAcrossTheNativeBoundary(acknowledged: Bool) throws {
    let native = Driver()
    var events: [ManualWiFiBluetoothTrace.Event] = []
    let driver = ManualWiFiBluetoothDriver(native: native, trace: { _, event in events.append(event) })
    var forwarded: [UUID] = []
    driver.eventHandler = { event in
      if case .protocolEvent(let session, _) = event { forwarded.append(session) }
    }
    let peripheral = UUID()
    let session = UUID()
    let readiness = BLEGATTCharacteristic(
      service: "4c0020fe-f3b6-40de-acc9-77d129067b14",
      characteristic: "a68e3f66-0fcc-4395-8d4c-aa980b5877fa")
    let password = BLEProtocolAction.read(ProbeImageViewingLaunch.password)
    let standard = BLEProtocolAction.write(
      ProbeImageViewingLaunch.launch, Data([0x04, 0x00]), .activateWiFi)
    driver.connect(peripheralID: peripheral, session: session)
    native.eventHandler?(.peerModel(session, "FF220001"))
    driver.perform(.subscribe(readiness), session: session)
    native.eventHandler?(.protocolEvent(session, .subscribed(readiness)))
    try driver.beginImageViewingActivation(peripheralID: peripheral) { true }
    driver.perform(password, session: session)
    native.eventHandler?(.protocolEvent(UUID(), .read(ProbeImageViewingLaunch.password, Data())))
    native.eventHandler?(.protocolEvent(session, .read(ProbeImageViewingLaunch.password, Data("secret123".utf8))))
    driver.perform(standard, session: session)
    native.eventHandler?(.protocolEvent(session, .notification(readiness, Data([1, 42]))))
    native.eventHandler?(.protocolEvent(session, .notification(readiness, Data([0]))))
    native.eventHandler?(.protocolEvent(session, .notification(readiness, Data([9]))))
    native.eventHandler?(.protocolEvent(UUID(), .wrote(ProbeImageViewingLaunch.launch)))
    if acknowledged { native.eventHandler?(.protocolEvent(session, .wrote(ProbeImageViewingLaunch.launch))) }

    #expect(native.actions == [.subscribe(readiness), password, .write(ProbeImageViewingLaunch.launch, Data([3, 0]), .activateWiFi)])
    #expect(forwarded == Array(repeating: session, count: acknowledged ? 4 : 2))
    var expected: [ManualWiFiBluetoothTrace.Event] = [
      .connectionRequested, .peerModel(.xt5), .subscription(.readiness, .requested),
      .subscription(.readiness, .accepted), .activationAuthorized, .passwordReadRequested,
      .passwordReadCompleted, .imageViewing03Submitted(ordinal: 1), .readiness(.positive, length: 2),
      .readiness(.negative, length: 1), .readiness(.unrecognized, length: 1)
    ]
    if acknowledged { expected.append(.launchWriteAcknowledged) }
    #expect(events == expected)
  }

  @Test func tracesSuppressedWritesAndCurrentTerminalEvents() throws {
    let native = Driver()
    var events: [ManualWiFiBluetoothTrace.Event] = []
    let driver = ManualWiFiBluetoothDriver(native: native, trace: { _, event in events.append(event) })
    let peripheral = UUID()
    let oldSession = UUID()
    let session = UUID()
    var currentRejections = 0
    driver.eventHandler = { event in
      if case .linkFailed(session, .unsupportedProtocol) = event { currentRejections += 1 }
    }
    let geotag = BLEGATTCharacteristic(
      service: "4c0020fe-f3b6-40de-acc9-77d129067b14",
      characteristic: "ad06c7b7-f41a-46f4-a29a-712055319122")
    let alternate = BLEProtocolAction.write(ProbeImageViewingLaunch.launch, Data([3, 0]), .activateWiFi)
    driver.connect(peripheralID: peripheral, session: oldSession)
    driver.connect(peripheralID: peripheral, session: session)
    native.eventHandler?(.peerModel(oldSession, "X-E3"))
    native.eventHandler?(.linkFailed(oldSession, .authentication))
    native.eventHandler?(.disconnected(oldSession, .connectionLost))
    native.eventHandler?(.protocolEvent(session, .services([])))
    driver.perform(.subscribe(geotag), session: session)
    native.eventHandler?(.protocolEvent(session, .subscriptionUnavailable(geotag)))
    driver.perform(.subscribe(geotag), session: session)
    native.eventHandler?(.protocolEvent(session, .failed(geotag, .unsupportedProtocol)))
    native.eventHandler?(.peerModel(session, "X-T5"))
    try driver.beginImageViewingActivation(peripheralID: peripheral) { true }
    driver.perform(alternate, session: session)
    native.eventHandler?(.disconnected(session, .connectionLost))

    #expect(native.actions == [.subscribe(geotag), .subscribe(geotag)])
    #expect(currentRejections == 1)
    #expect(events == [
      .connectionRequested, .connectionRequested,
      .subscription(.readiness, .notDiscovered), .subscription(.secondIndication, .notDiscovered),
      .subscription(.configuration, .notDiscovered), .subscription(.geotag, .notDiscovered),
      .subscription(.ssid, .notDiscovered), .subscription(.geotag, .requested),
      .subscription(.geotag, .unavailable), .subscription(.geotag, .requested),
      .subscription(.geotag, .failed), .peerModel(.xt5), .activationAuthorized,
      .activationRejected(.unsupportedProtocol), .disconnected(.connectionLost)
    ])
  }

  @Test func traceFileIsBoundedRedactedAndReset() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    let report = ManualWiFiBluetoothTrace(file: file)
    let native = Driver()
    let driver = ManualWiFiBluetoothDriver(native: native, trace: report.append)
    let peripheral = UUID()
    let session = UUID()
    let readiness = BLEGATTCharacteristic(
      service: "4c0020fe-f3b6-40de-acc9-77d129067b14",
      characteristic: "a68e3f66-0fcc-4395-8d4c-aa980b5877fa")
    let payload = Data(repeating: 65, count: 32_768)
    for _ in 0..<160 { driver.connect(peripheralID: peripheral, session: UUID()) }
    driver.connect(peripheralID: peripheral, session: session)
    native.eventHandler?(.peerModel(session, "private-camera-name"))
    native.eventHandler?(.peerModel(session, "FF220001"))
    try driver.beginImageViewingActivation(peripheralID: peripheral) { true }
    driver.perform(.read(ProbeImageViewingLaunch.password), session: session)
    native.eventHandler?(.protocolEvent(session, .read(ProbeImageViewingLaunch.password, Data("private-password".utf8))))
    driver.perform(.write(ProbeImageViewingLaunch.launch, Data([4, 0]), .activateWiFi), session: session)
    for _ in 0..<300 { native.eventHandler?(.protocolEvent(session, .notification(readiness, payload))) }
    native.eventHandler?(.protocolEvent(session, .wrote(ProbeImageViewingLaunch.launch)))
    driver.disconnect(session: session)
    native.eventHandler?(.disconnected(session, .connectionLost))

    let data = try Data(contentsOf: file)
    let records = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    let json = String(decoding: data, as: UTF8.self)
    #expect(records.count == 128)
    #expect(records.last?["attempt"] as? Int == 161)
    let readinessRecords = records.compactMap { ($0["event"] as? [String: Any])?["readiness"] as? [String: Any] }
    #expect(readinessRecords.count == 8)
    #expect(readinessRecords.allSatisfy { $0["_0"] as? String == "unrecognized" })
    #expect(json.contains("\"length\":512"))
    #expect(json.contains("launchWriteAcknowledged"))
    #expect(json.contains("disconnected"))
    for secret in ["private-camera-name", "private-password", "FF220001", peripheral.uuidString,
      session.uuidString, readiness.characteristic, payload.base64EncodedString(), "32768"]
    {
      #expect(!json.contains(secret))
    }
    _ = ManualWiFiBluetoothTrace(file: file)
    #expect(try String(contentsOf: file, encoding: .utf8) == "[]")
  }

  @Test func earlyDuplicateBusyWaitsForAcknowledgmentAndTwoRetriesCanReachReady() throws {
    let flow = try LaunchFlow()
    flow.notify([0, 0])
    flow.notify([0])
    #expect(flow.timer.requests.isEmpty)
    #expect(flow.failures.isEmpty)
    #expect(flow.native.actions == [flow.passwordRead, flow.imageViewing])
    flow.acknowledge()
    flow.notify([0])
    try #require(flow.timer.requests.map(\.delay) == [.milliseconds(200)])
    #expect(flow.failures.isEmpty)
    flow.timer.fire(0)
    flow.acknowledge()
    flow.notify([0])
    try #require(flow.timer.requests.map(\.delay) == [.milliseconds(200), .milliseconds(200)])
    flow.timer.fire(1)
    flow.notify([1, 42])
    #expect(!flow.ready)
    flow.acknowledge()
    #expect(flow.ready)
    #expect(flow.failures.isEmpty)
    #expect(flow.native.actions == [flow.passwordRead, flow.imageViewing, flow.imageViewing, flow.imageViewing])
    #expect(flow.trace.filter {
      if case .readiness(.negative, length: _) = $0 { return true }
      return false
    }.count == 4)
    #expect(flow.trace.filter {
      switch $0 {
      case .imageViewing03Submitted, .imageViewingRetryScheduled: return true
      default: return false
      }
    } == [.imageViewing03Submitted(ordinal: 1), .imageViewingRetryScheduled(ordinal: 2),
      .imageViewing03Submitted(ordinal: 2), .imageViewingRetryScheduled(ordinal: 3),
      .imageViewing03Submitted(ordinal: 3)])
  }

  @Test func thirdBusyFailsThroughProfileOnlyAfterItsAcknowledgment() throws {
    let flow = try LaunchFlow()
    for index in 0..<2 {
      flow.acknowledge()
      flow.notify([0])
      try #require(flow.timer.requests.count == index + 1)
      flow.timer.fire(index)
    }
    flow.notify([0])
    flow.notify([0])
    #expect(flow.failures.isEmpty)
    flow.acknowledge()
    #expect(flow.failures == [.cameraBusy])
    #expect(flow.trace.last == .imageViewingRetriesExhausted)
    #expect(flow.timer.requests.count == 2)
    #expect(flow.native.actions == [flow.passwordRead, flow.imageViewing, flow.imageViewing, flow.imageViewing])
    #expect(!flow.ready)
  }

  @Test func cachedBusyProgressAndUnknownBytesCannotScheduleOrSucceed() throws {
    let flow = try LaunchFlow(launchImmediately: false)
    flow.notify([0, 0])
    flow.launch()
    flow.acknowledge()
    for bytes: [UInt8] in [[2, 128], [9], [], [0, 0, 0], [1, 0, 0]] { flow.notify(bytes) }
    #expect(flow.trace.contains(.readiness(.launching, length: 2)))
    #expect(flow.timer.requests.isEmpty)
    #expect(flow.failures.isEmpty)
    #expect(!flow.ready)
    #expect(flow.native.actions == [flow.passwordRead, flow.imageViewing])
  }

  @Test func readyDuringDelayCancelsRetryAndIgnoresLateTimer() throws {
    let flow = try LaunchFlow()
    flow.acknowledge()
    flow.notify([0])
    let request = try #require(flow.timer.requests.first)
    flow.notify([1])
    #expect(flow.ready)
    #expect(flow.failures.isEmpty)
    #expect(request.cancelled)
    flow.timer.fire(0)
    #expect(flow.native.actions == [flow.passwordRead, flow.imageViewing])
  }

  enum Interruption: CaseIterable {
    case cancel, disconnected, replacement, reconnect, failedWrite, linkFailure, changedModel
  }

  @Test(arguments: Interruption.allCases) func interruptedDelayCannotWriteAgain(interruption: Interruption) throws {
    let flow = try LaunchFlow()
    flow.acknowledge()
    flow.notify([0])
    let request = try #require(flow.timer.requests.first)
    switch interruption {
    case .cancel: flow.driver.disconnect(session: flow.session)
    case .disconnected: flow.native.eventHandler?(.disconnected(flow.session, .connectionLost))
    case .replacement: flow.current = false
    case .reconnect:
      flow.driver.connect(peripheralID: flow.peripheral, session: UUID())
    case .failedWrite: flow.emit(.failed(ProbeImageViewingLaunch.launch, .connectionLost))
    case .linkFailure: flow.native.eventHandler?(.linkFailed(flow.session, .connectionLost))
    case .changedModel: flow.native.eventHandler?(.peerModel(flow.session, "X-E3"))
    }
    flow.timer.fire(0)
    #expect(request.cancelled)
    #expect(flow.native.actions == [flow.passwordRead, flow.imageViewing])
    #expect(!flow.ready)
  }

  @Test func previousSessionBusyAndAcknowledgmentCannotTriggerCurrentRetry() throws {
    let flow = try LaunchFlow()
    let stale = UUID()
    flow.native.eventHandler?(.protocolEvent(stale, .notification(flow.readiness, Data([0, 0]))))
    flow.native.eventHandler?(.protocolEvent(stale, .wrote(ProbeImageViewingLaunch.launch)))
    flow.acknowledge()
    #expect(flow.timer.requests.isEmpty)
    #expect(flow.failures.isEmpty)
    #expect(flow.native.actions == [flow.passwordRead, flow.imageViewing])
  }

  @MainActor
  private final class RetryTimer {
    final class Request {
      let delay: Duration
      let body: @MainActor () -> Void
      var cancelled = false

      init(delay: Duration, body: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.body = body
      }
    }

    var requests: [Request] = []

    func schedule(_ delay: Duration, _ body: @escaping @MainActor () -> Void) -> () -> Void {
      let request = Request(delay: delay, body: body)
      requests.append(request)
      return { request.cancelled = true }
    }

    func fire(_ index: Int) {
      // Deliver even a cancelled callback to exercise the driver's stale-work guard.
      requests[index].body()
    }
  }

  @MainActor
  private final class LaunchFlow {
    let native = Driver()
    let timer = RetryTimer()
    let peripheral = UUID()
    let session = UUID()
    let readiness = ManualWiFiBluetoothTrace.Subscription.readiness.characteristic
    let passwordRead = BLEProtocolAction.read(ProbeImageViewingLaunch.password)
    let imageViewing = BLEProtocolAction.write(ProbeImageViewingLaunch.launch, Data([3, 0]), .activateWiFi)
    var current = true
    var ready = false
    var failures: [WirelessFailure] = []
    var trace: [ManualWiFiBluetoothTrace.Event] = []
    private var profile = XT5BLEProfile()
    lazy var driver = ManualWiFiBluetoothDriver(
      native: native, trace: { [weak self] _, event in self?.trace.append(event) },
      scheduleRetry: timer.schedule)

    init(launchImmediately: Bool = true) throws {
      let secure = BLEGATTCharacteristic(
        service: "123d8f06-62a1-4935-9322-833c531ee225",
        characteristic: "f557d96b-8284-4667-8793-b971c1deca2a")
      let identity = BLEGATTCharacteristic(
        service: secure.service, characteristic: "85b9163e-62d1-49ff-a6f5-054b4630d4a1")
      let configuration = ManualWiFiBluetoothTrace.Subscription.configuration.characteristic
      let geotag = ManualWiFiBluetoothTrace.Subscription.geotag.characteristic
      let ssid = ManualWiFiBluetoothTrace.Subscription.ssid.characteristic
      for event: BLEProtocolEvent in [
        .services([secure, identity, readiness, configuration, geotag, ssid,
          ProbeImageViewingLaunch.password, ProbeImageViewingLaunch.launch]),
        .read(secure, Data([0, 0, 0, 0])), .wrote(secure), .wrote(identity),
        .read(ssid, Data("test-network".utf8)), .subscribed(readiness),
        .subscribed(configuration), .subscribed(geotag), .subscribed(ssid),
      ] {
        _ = try profile.receive(event)
      }
      driver.connect(peripheralID: peripheral, session: session)
      native.eventHandler?(.peerModel(session, "X-T5"))
      driver.eventHandler = { [weak self] event in
        guard let self else { return }
        switch event {
        case .protocolEvent(self.session, let event): self.advance(event)
        case .linkFailed(self.session, let failure): self.failures.append(failure)
        default: break
        }
      }
      try driver.beginImageViewingActivation(peripheralID: peripheral) { [weak self] in self?.current == true }
      advance(.activateWiFi)
      if launchImmediately { launch() }
    }

    func launch() {
      emit(.read(ProbeImageViewingLaunch.password, Data("example-secret".utf8)))
    }

    func notify(_ bytes: [UInt8]) { emit(.notification(readiness, Data(bytes))) }

    func acknowledge() { emit(.wrote(ProbeImageViewingLaunch.launch)) }

    func emit(_ event: BLEProtocolEvent) { native.eventHandler?(.protocolEvent(session, event)) }

    private func advance(_ event: BLEProtocolEvent) {
      do {
        for action in try profile.receive(event) {
          if case .wifiReady = action { ready = true; continue }
          driver.perform(action, session: session)
        }
      } catch let failure as WirelessFailure {
        failures.append(failure)
      } catch {
        Issue.record(error)
      }
    }
  }

  private final class Driver: BluetoothPeripheralDriver {
    var eventHandler: ((BluetoothDriverEvent) -> Void)?
    var actions: [BLEProtocolAction] = []

    func start(allowPermissionPrompt: Bool) throws {}
    func scan() {}
    func stopScan() {}
    func discardDiscoveries() {}
    func connect(peripheralID: UUID, session: UUID) {}
    func perform(_ action: BLEProtocolAction, session: UUID) { actions.append(action) }
    func disconnect(session: UUID) {}
  }
}
