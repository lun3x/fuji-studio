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

  @Test func forwardsOnlyTheOrderedStandardActivationForTheSelectedSession() throws {
    let native = Driver()
    let driver = ManualWiFiBluetoothDriver(native: native)
    let peripheral = UUID()
    let session = UUID()
    let password = BLEProtocolAction.read(ProbeImageViewingLaunch.password)
    let standard = BLEProtocolAction.write(
      ProbeImageViewingLaunch.launch, Data([0x04, 0x00]), .activateWiFi)
    driver.connect(peripheralID: peripheral, session: session)
    native.eventHandler?(.peerModel(session, "X-T5"))
    try driver.beginStandardActivation(peripheralID: peripheral) { true }
    driver.perform(password, session: session)
    native.eventHandler?(.protocolEvent(UUID(), .read(ProbeImageViewingLaunch.password, Data())))
    #expect(native.actions == [password])
    native.eventHandler?(.protocolEvent(session, .read(ProbeImageViewingLaunch.password, Data())))
    driver.perform(standard, session: UUID())
    driver.perform(standard, session: session)
    #expect(native.actions == [password, standard])

    driver.disconnect(session: session)
    driver.perform(standard, session: session)
    #expect(native.actions == [password, standard])
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
    try driver.beginStandardActivation(peripheralID: peripheral) { current }
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
    try driver.beginStandardActivation(peripheralID: peripheral) { true }
    driver.perform(password, session: session)
    native.eventHandler?(.protocolEvent(UUID(), .read(ProbeImageViewingLaunch.password, Data())))
    native.eventHandler?(.protocolEvent(session, .read(ProbeImageViewingLaunch.password, Data("secret123".utf8))))
    driver.perform(standard, session: session)
    native.eventHandler?(.protocolEvent(session, .notification(readiness, Data([1, 42]))))
    native.eventHandler?(.protocolEvent(session, .notification(readiness, Data([0]))))
    native.eventHandler?(.protocolEvent(session, .notification(readiness, Data([9]))))
    native.eventHandler?(.protocolEvent(UUID(), .wrote(ProbeImageViewingLaunch.launch)))
    if acknowledged { native.eventHandler?(.protocolEvent(session, .wrote(ProbeImageViewingLaunch.launch))) }

    #expect(native.actions == [.subscribe(readiness), password, standard])
    #expect(forwarded == Array(repeating: session, count: acknowledged ? 6 : 5))
    var expected: [ManualWiFiBluetoothTrace.Event] = [
      .connectionRequested, .peerModel(.xt5), .subscription(.readiness, .requested),
      .subscription(.readiness, .accepted), .activationAuthorized, .passwordReadRequested,
      .passwordReadCompleted, .standard04Submitted, .readiness(.positive, length: 2),
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
    try driver.beginStandardActivation(peripheralID: peripheral) { true }
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
    try driver.beginStandardActivation(peripheralID: peripheral) { true }
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
