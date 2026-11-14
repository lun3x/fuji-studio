import Foundation
import FujiCameraCore
import XCTest

@testable import FujiStudio

@MainActor
final class BluetoothGatewayTests: XCTestCase {
  func testSavedReconnectDoesNotPairAgainOrExposeSecrets() async throws {
    let namespace = "FujiStudio.Tests.BluetoothGateway.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
    let store = KeychainCameraStore(
      defaults: defaults, service: namespace, keychain: ReplayCameraKeychain(service: namespace))
    let camera = SavedCamera(
      id: WirelessCameraID(), peripheralID: UUID(), model: .xe3, displayName: "SerialABCDEF")
    defer {
      defaults.removePersistentDomain(forName: namespace)
    }
    let token = WirelessProtocolPeerKey(bytes: Data("TKN!".utf8))
    let paired = try store.savePaired(camera, peerKey: token)
    let driver = ReplayBluetoothDriver()
    let gateway = NativeBluetoothGateway(store: store, driver: driver)
    let events = await gateway.events()
    var eventIterator = events.makeAsyncIterator()
    XCTAssertEqual(driver.startRequests, [])

    try await gateway.reconnect(paired)
    XCTAssertEqual(driver.startRequests, [false])
    XCTAssertEqual(driver.reconnectedPeripheralIDs, [camera.peripheralID])
    XCTAssertFalse(driver.writes.contains { $0.1 == .pair })
    XCTAssertTrue(driver.writes.contains { $0.0 == Data("TKN!".utf8) && $0.1 == .authenticate })
    let network = try await gateway.activateWiFi(for: camera.id)
    XCTAssertEqual(network.security, .wpaPersonal)
    XCTAssertEqual(network.ssid, "SecretSSID")
    let credential = try await store.password(for: network.credential)
    XCTAssertEqual(credential, "PrivatePassphrase")
    let state = await eventIterator.next()
    XCTAssertEqual(state, .availability(.poweredOn))
    driver.dropConnection()
    let dropped = await eventIterator.next()
    XCTAssertEqual(dropped, .disconnected(camera.id, .connectionLost))
    driver.setAvailability(.poweredOff)
    let power = await eventIterator.next()
    XCTAssertEqual(power, .availability(.poweredOff))
    driver.setAvailability(.unauthorized)
    let authorization = await eventIterator.next()
    XCTAssertEqual(authorization, .availability(.unauthorized))

    let diagnostic = String(reflecting: [paired as Any, network as Any, driver.actions as Any])
    for secret in ["SerialABCDEF", "TKN!", "SecretSSID", "PrivatePassphrase", camera.peripheralID.uuidString] {
      XCTAssertFalse(diagnostic.contains(secret))
    }
    await gateway.disconnect()
  }

  func testCancelledReconnectWaitsForNativeCleanupAndRejectsLateAuthentication() async throws {
    let namespace = "FujiStudio.Tests.BluetoothCancellation.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
    defer { defaults.removePersistentDomain(forName: namespace) }
    let store = KeychainCameraStore(
      defaults: defaults, service: namespace, keychain: ReplayCameraKeychain(service: namespace))
    let camera = try store.savePaired(
      SavedCamera(
        id: WirelessCameraID(), peripheralID: UUID(), model: .xe3, displayName: "Travel camera"),
      peerKey: WirelessProtocolPeerKey(bytes: Data("TKN!".utf8)))
    let driver = ReplayBluetoothDriver()
    let gateway = NativeBluetoothGateway(store: store, driver: driver)
    driver.pauseConnections = true
    driver.pauseDisconnects = true
    let (connects, connectSignal) = AsyncStream<UUID>.makeStream()
    driver.onConnect = { connectSignal.yield($0) }
    let (disconnects, disconnectSignal) = AsyncStream<UUID>.makeStream()
    driver.onDisconnect = { disconnectSignal.yield($0) }
    defer {
      connectSignal.finish()
      disconnectSignal.finish()
    }
    var attempts = connects.makeAsyncIterator()
    var cancellations = disconnects.makeAsyncIterator()
    var completionBeforeCleanup = false
    let cancelled = Task { @MainActor in
      defer { completionBeforeCleanup = driver.connection != nil }
      try await gateway.reconnect(camera)
    }
    let firstAttempt = await attempts.next()
    let first = try XCTUnwrap(firstAttempt)
    cancelled.cancel()
    let cancelling = await cancellations.next()
    XCTAssertEqual(cancelling, first)
    driver.reportServices(for: first)
    XCTAssertTrue(driver.writes.isEmpty)
    // Let a prematurely resumed reconnect run before the terminal native event.
    await Task.yield()
    driver.dropConnection()
    do {
      try await cancelled.value
      XCTFail("Cancelled reconnect returned success")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertFalse(completionBeforeCleanup)

    let retry = Task { @MainActor in try await gateway.reconnect(camera) }
    let secondAttempt = await attempts.next()
    let second = try XCTUnwrap(secondAttempt)
    XCTAssertNotEqual(second, first)
    driver.reportServices(for: first)
    XCTAssertTrue(driver.writes.isEmpty)
    driver.reportServices(for: second)
    try await retry.value
    XCTAssertEqual(driver.writes.map(\.1), [.authenticate, .identify])
    driver.pauseDisconnects = false
    await gateway.disconnect()
  }

  func testRenamedCameraWithoutAReadableModelRequiresExplicitResolution() async throws {
    let namespace = "FujiStudio.Tests.BluetoothIdentity.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
    defer { defaults.removePersistentDomain(forName: namespace) }
    let store = KeychainCameraStore(
      defaults: defaults, service: namespace, keychain: ReplayCameraKeychain(service: namespace))
    let driver = ReplayBluetoothDriver()
    let gateway = NativeBluetoothGateway(store: store, driver: driver)
    let stream = try await gateway.discover()
    let camera = DiscoveredCamera(
      peripheralID: UUID(), advertisedModelHint: nil, displayName: "Travel camera")
    driver.eventHandler?(.discovered(camera, token: WirelessProtocolPeerKey(bytes: Data("TKN!".utf8))))
    var discoveries = stream.makeAsyncIterator()
    let candidates = try await discoveries.next()
    XCTAssertEqual(candidates, [camera])
    do {
      _ = try await gateway.pair(camera)
      XCTFail("Pairing returned a camera without a model")
    } catch {
      XCTAssertEqual(error as? BluetoothPairingFailure, .unresolvedModel)
    }
    XCTAssertTrue(driver.writes.isEmpty)
    let saved = try await store.cameras()
    XCTAssertTrue(saved.isEmpty)
  }

  func testEndingDiscoveryWhilePairStartsDoesNotStopTheLink() async throws {
    let namespace = "FujiStudio.Tests.BluetoothPair.\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
    defer { defaults.removePersistentDomain(forName: namespace) }
    let store = KeychainCameraStore(
      defaults: defaults, service: namespace, keychain: ReplayCameraKeychain(service: namespace))
    let driver = ReplayBluetoothDriver()
    let gateway = NativeBluetoothGateway(store: store, driver: driver)
    let stream = try await gateway.discover()
    let camera = DiscoveredCamera(
      peripheralID: UUID(), advertisedModelHint: nil, displayName: "Travel camera")
    driver.eventHandler?(.discovered(camera, token: WirelessProtocolPeerKey(bytes: Data("PAIR".utf8))))
    var discoveries = stream.makeAsyncIterator()
    let candidates = try await discoveries.next()
    XCTAssertEqual(candidates, [camera])
    driver.peerModel = "X-E3"
    driver.pauseConnections = true
    let (connects, signal) = AsyncStream<UUID>.makeStream()
    driver.onConnect = { signal.yield($0) }
    defer { signal.finish() }
    var attempt = connects.makeAsyncIterator()
    let pairing = Task { @MainActor in try await gateway.pair(camera) }
    let session = await attempt.next()
    let link = try XCTUnwrap(session)
    let endOfDiscovery = try await discoveries.next()
    XCTAssertNil(endOfDiscovery)
    await Task.yield()
    driver.reportServices(for: link)
    let saved = try await pairing.value
    XCTAssertEqual(saved.model, .xe3)
    let identity = try await gateway.identity(for: saved.id)
    XCTAssertEqual(saved.id, identity.cameraID)
    XCTAssertEqual(driver.writes.map(\.1), [.pair, .identify])
    let stored = try await store.cameras()
    XCTAssertEqual(stored, [saved])
    let selected = try await store.selected()
    XCTAssertNil(selected)
    await gateway.disconnect()
  }
}

@MainActor
private final class ReplayBluetoothDriver: BluetoothPeripheralDriver {
  var eventHandler: ((BluetoothDriverEvent) -> Void)?
  var startRequests: [Bool] = []
  var reconnectedPeripheralIDs: [UUID] = []
  var writes: [(Data, BLEWritePurpose)] = []
  var actions: [BLEProtocolAction] = []
  var connection: UUID?
  var onConnect: ((UUID) -> Void)?
  var onDisconnect: ((UUID) -> Void)?
  var pauseConnections = false
  var pauseDisconnects = false
  var peerModel: String?
  private let token = BLEGATTCharacteristic(
    service: "91f1de68-dff6-466e-8b65-ff13b0f16fb8",
    characteristic: "aba356eb-9633-4e60-b73f-f52516dbd671")
  private let name = BLEGATTCharacteristic(
    service: "91f1de68-dff6-466e-8b65-ff13b0f16fb8",
    characteristic: "85b9163e-62d1-49ff-a6f5-054b4630d4a1")
  private let readiness = BLEGATTCharacteristic(
    service: "4c0020fe-f3b6-40de-acc9-77d129067b14",
    characteristic: "a68e3f66-0fcc-4395-8d4c-aa980b5877fa")
  private let ssid = BLEGATTCharacteristic(
    service: "4e941240-d01d-46b9-a5ea-67636806830b",
    characteristic: "bf6dc9cf-3606-4ec9-a4c8-d77576e93ea4")
  private let password = BLEGATTCharacteristic(
    service: "4e941240-d01d-46b9-a5ea-67636806830b",
    characteristic: "e809256a-915c-4967-92e8-53b7d4cad213")
  private let launch = BLEGATTCharacteristic(
    service: "6514eb81-4e8f-458d-aa2a-e691336cdfac",
    characteristic: "600655e6-3637-42f1-8fb2-44efc5c63b13")

  func start(allowPermissionPrompt: Bool) throws {
    startRequests.append(allowPermissionPrompt)
    setAvailability(.poweredOn)
  }

  func scan() {}
  func stopScan() {}

  func connect(peripheralID: UUID, session: UUID) {
    reconnectedPeripheralIDs.append(peripheralID)
    connection = session
    onConnect?(session)
    if !pauseConnections { reportServices(for: session) }
  }

  func reportServices(for session: UUID) {
    eventHandler?(.peerModel(session, peerModel))
    eventHandler?(.protocolEvent(session, .services([token, name, readiness, ssid, password, launch])))
  }

  func perform(_ action: BLEProtocolAction, session: UUID) {
    actions.append(action)
    switch action {
    case .read(let characteristic):
      let value = characteristic == ssid ? "SecretSSID" : "PrivatePassphrase"
      eventHandler?(.protocolEvent(session, .read(characteristic, Data(value.utf8))))
    case .write(let characteristic, let value, let purpose):
      writes.append((value, purpose))
      eventHandler?(.protocolEvent(session, .wrote(characteristic)))
      if characteristic == launch {
        eventHandler?(.protocolEvent(session, .notification(readiness, Data([1, 0]))))
      }
    case .subscribe(let characteristic):
      eventHandler?(.protocolEvent(session, .subscribed(characteristic)))
    default:
      XCTFail("Unexpected driver action")
    }
  }

  func disconnect(session: UUID) {
    onDisconnect?(session)
    if !pauseDisconnects { dropConnection() }
  }

  func dropConnection() {
    guard let session = connection else { return }
    connection = nil
    eventHandler?(.disconnected(session, .connectionLost))
  }

  func setAvailability(_ value: BluetoothAvailability) {
    eventHandler?(.availability(value))
  }
}
