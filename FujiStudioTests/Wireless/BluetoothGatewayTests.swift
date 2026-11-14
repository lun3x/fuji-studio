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
    let cancelled = Task { @MainActor in
      try await gateway.reconnect(camera)
    }
    let firstAttempt = await attempts.next()
    let first = try XCTUnwrap(firstAttempt)
    cancelled.cancel()
    let cancelling = await cancellations.next()
    XCTAssertEqual(cancelling, first)
    let cleanupCompleted = expectation(description: "Explicit disconnect joined native cleanup")
    cleanupCompleted.isInverted = true
    let cleanup = Task { @MainActor in
      await gateway.disconnect()
      if driver.connection != nil { cleanupCompleted.fulfill() }
    }
    let reconnectCompleted = expectation(description: "Reconnect finishes during native cleanup")
    reconnectCompleted.isInverted = true
    let completion = Task { @MainActor in
      _ = await cancelled.result
      if driver.connection != nil { reconnectCompleted.fulfill() }
    }
    driver.reportServices(for: first)
    XCTAssertTrue(driver.writes.isEmpty)
    await fulfillment(of: [cleanupCompleted, reconnectCompleted], timeout: 0.15)
    driver.dropConnection()
    do {
      try await cancelled.value
      XCTFail("Cancelled reconnect returned success")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    await cleanup.value
    await completion.value

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

  func testDisconnectInvalidatesPairAndReconnectWhileSavedLookupIsSuspended() async throws {
    for pairing in [true, false] {
      let camera = SavedCamera(
        id: WirelessCameraID(), peripheralID: UUID(), model: .xe3, displayName: "Travel camera")
      let store = SuspendedCameraLookup(camera: camera)
      let driver = ReplayBluetoothDriver()
      let gateway = NativeBluetoothGateway(store: store, driver: driver)
      let candidate = DiscoveredCamera(
        peripheralID: camera.peripheralID, advertisedModelHint: camera.model,
        displayName: camera.displayName)
      let discovery = pairing ? try await gateway.discover() : nil
      if pairing {
        driver.eventHandler?(.discovered(candidate, token: store.token))
      }
      let attempt = Task { @MainActor in
        if pairing {
          _ = try await gateway.pair(candidate)
        } else {
          try await gateway.reconnect(camera)
        }
      }
      var lookup = store.lookups.makeAsyncIterator()
      _ = await lookup.next()
      await gateway.disconnect()
      store.resumeLookup()
      do {
        try await attempt.value
        XCTFail("An invalidated request proceeded after disconnect")
      } catch {
        XCTAssertTrue(error is CancellationError)
      }
      withExtendedLifetime(discovery) {}
      XCTAssertTrue(driver.reconnectedPeripheralIDs.isEmpty)
      XCTAssertTrue(driver.writes.isEmpty)
      XCTAssertFalse(store.savedPair)
    }
  }

  func testPowerLossInvalidatesAdvertisementBeforePairing() async throws {
    let camera = SavedCamera(
      id: WirelessCameraID(), peripheralID: UUID(), model: .xe3, displayName: "Travel camera")
    let store = SuspendedCameraLookup(camera: camera)
    let driver = ReplayBluetoothDriver()
    let gateway = NativeBluetoothGateway(store: store, driver: driver)
    let stream = try await gateway.discover()
    let candidate = DiscoveredCamera(
      peripheralID: camera.peripheralID, advertisedModelHint: camera.model,
      displayName: camera.displayName)
    driver.eventHandler?(.discovered(candidate, token: store.token))
    driver.setAvailability(.poweredOff)
    driver.setAvailability(.poweredOn)
    store.suspend = false
    do {
      _ = try await gateway.pair(candidate)
      XCTFail("Pairing reused an advertisement from before a radio interruption")
    } catch {
      XCTAssertEqual(error as? WirelessFailure, .peerMismatch)
    }
    withExtendedLifetime(stream) {}
    XCTAssertTrue(driver.writes.isEmpty)
  }

  func testFullDisconnectDiscardsNativeDiscoveryWithoutAnActiveLink() async throws {
    let store = SuspendedCameraLookup(camera: SavedCamera(
      id: WirelessCameraID(), peripheralID: UUID(), model: .xt5, displayName: "Travel camera"))
    let driver = ReplayBluetoothDriver()
    let gateway = NativeBluetoothGateway(store: store, driver: driver)
    let stream = try await gateway.discover()
    XCTAssertEqual(driver.discoveryDiscardCount, 0)
    await gateway.disconnect()
    withExtendedLifetime(stream) {}
    XCTAssertEqual(driver.discoveryDiscardCount, 1)
  }

  func testReconnectHintCannotOverrideAnOptionalModelReadFailure() async throws {
    let saved = SavedCamera(
      id: WirelessCameraID(), peripheralID: UUID(), model: .xe3, displayName: "X-E3")
    let store = SuspendedCameraLookup(camera: saved)
    store.suspend = false
    for error in [WirelessFailure.authentication, .connectionLost] {
      let driver = ReplayBluetoothDriver()
      driver.pauseConnections = true
      let gateway = NativeBluetoothGateway(store: store, driver: driver)
      driver.onConnect = { session in
        driver.eventHandler?(.linkFailed(session, error))
        driver.reportServices(for: session)
      }
      do {
        try await gateway.reconnect(saved)
        XCTFail("Reconnect fell back to the saved model after a terminal model read failure")
      } catch let received {
        XCTAssertEqual(received as? WirelessFailure, error)
      }
      XCTAssertTrue(driver.writes.isEmpty)
      driver.onConnect = nil
    }
  }
}

@MainActor
private final class SuspendedCameraLookup: CameraPairingStore {
  let token = WirelessProtocolPeerKey(bytes: Data("TOKN".utf8))
  let camera: SavedCamera
  let (lookups, signal) = AsyncStream<Void>.makeStream()
  var suspend = true
  private var lookup: CheckedContinuation<Void, Never>?
  private(set) var savedPair = false

  init(camera: SavedCamera) { self.camera = camera }

  func cameras() async throws -> [SavedCamera] {
    if suspend {
      await withCheckedContinuation { continuation in
        lookup = continuation
        signal.yield(())
      }
    }
    return [camera]
  }

  func resumeLookup() {
    let pending = lookup
    lookup = nil
    pending?.resume()
  }

  func savePaired(_ camera: SavedCamera, peerKey: WirelessProtocolPeerKey?) throws -> SavedCamera {
    savedPair = true
    return camera
  }
  func peerKey(for camera: SavedCamera) throws -> WirelessProtocolPeerKey? { token }
  func savePassword(_ password: String, for id: WirelessCameraID) throws -> CameraCredentialReference {
    throw WirelessFailure.peerMismatch
  }
  func selected() async throws -> WirelessCameraID? { camera.id }
  func save(_ camera: SavedCamera) async throws {}
  func select(_ id: WirelessCameraID) async throws {}
  func forget(_ id: WirelessCameraID) async throws {}
}

@MainActor
private final class ReplayBluetoothDriver: BluetoothPeripheralDriver {
  var eventHandler: ((BluetoothDriverEvent) -> Void)?
  var startRequests: [Bool] = []
  var reconnectedPeripheralIDs: [UUID] = []
  var writes: [(Data, BLEWritePurpose)] = []
  var actions: [BLEProtocolAction] = []
  private(set) var discoveryDiscardCount = 0
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
  func discardDiscoveries() { discoveryDiscardCount += 1 }

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
