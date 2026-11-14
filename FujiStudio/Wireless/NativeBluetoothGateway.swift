import Foundation
import FujiCameraCore

/// CoreBluetooth and replay callbacks run on the main serial executor.
@MainActor
protocol BluetoothPeripheralDriver: AnyObject {
  var eventHandler: ((BluetoothDriverEvent) -> Void)? { get set }

  func start(allowPermissionPrompt: Bool) throws
  func scan()
  func stopScan()
  func connect(peripheralID: UUID, session: UUID)
  func perform(_ action: BLEProtocolAction, session: UUID)
  /// Ends with a disconnected event, including when connection was still pending.
  func disconnect(session: UUID)
}

enum BluetoothDriverEvent {
  case availability(BluetoothAvailability)
  case discovered(DiscoveredCamera, token: WirelessProtocolPeerKey?)
  case peerModel(UUID, String?)
  case linkFailed(UUID, WirelessFailure)
  case protocolEvent(UUID, BLEProtocolEvent)
  case disconnected(UUID, WirelessFailure)
}

@MainActor
final class NativeBluetoothGateway: BluetoothGateway {
  private struct Advertisement {
    let camera: DiscoveredCamera
    let token: WirelessProtocolPeerKey?
  }

  private struct Session {
    let id = UUID()
    let peripheralID: UUID
    let displayName: String
    let modelHint: WirelessCameraModel?
    let rememberedCameras: [SavedCamera]
    var camera: SavedCamera?
    var peerModel: String?
    var profile: (any FujiBLEProfile)?
    var firmware: String?
    var authenticated = false
    var closing: (error: Error, reportIfLinked: Bool)?
  }

  private enum Pending {
    case link(Continuation, pairing: Bool, token: WirelessProtocolPeerKey?)
    case wifi(Continuation)

    var continuation: Continuation {
      switch self {
      case .link(let continuation, _, _), .wifi(let continuation): continuation
      }
    }
  }

  private enum Result {
    case linked(SavedCamera)
    case network(CameraNetwork)
  }

  private typealias Continuation = CheckedContinuation<Result, Error>
  private typealias Discovery = AsyncThrowingStream<[DiscoveredCamera], Error>

  private let store: any CameraPairingStore
  private let driver: any BluetoothPeripheralDriver
  private var availability = BluetoothAvailability.unknown
  private var advertisements: [UUID: Advertisement] = [:]
  private var discovery: (id: UUID, continuation: Discovery.Continuation)?
  private var eventContinuations: [UUID: AsyncStream<BluetoothGatewayEvent>.Continuation] = [:]
  private var session: Session?
  private var pending: Pending?
  private var timeout: Task<Void, Never>?
  private var operationID: UUID?
  private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []

  init(store: any CameraPairingStore, driver: any BluetoothPeripheralDriver = CoreBluetoothDriver()) {
    self.store = store
    self.driver = driver
    driver.eventHandler = { [weak self] event in self?.receive(event) }
  }

  func discover() async throws -> AsyncThrowingStream<[DiscoveredCamera], Error> {
    guard session == nil else { throw WirelessFailure.connectionLost }
    try Task.checkCancellation()
    try driver.start(allowPermissionPrompt: true)
    if let failure = availability.failure { throw failure }
    finishDiscovery()
    advertisements.removeAll()
    let id = UUID()
    let (stream, continuation) = Discovery.makeStream(bufferingPolicy: .bufferingNewest(1))
    continuation.onTermination = { [weak self] _ in
      Task { @MainActor in
        guard self?.discovery?.id == id else { return }
        self?.finishDiscovery()
      }
    }
    discovery = (id, continuation)
    continuation.yield([])
    if availability == .poweredOn { driver.scan() }
    return stream
  }

  func pair(_ camera: DiscoveredCamera) async throws -> SavedCamera {
    guard let advertisement = advertisements[camera.peripheralID], advertisement.camera == camera
    else { throw WirelessFailure.peerMismatch }
    let remembered = try await store.cameras().filter { $0.peripheralID == camera.peripheralID }
    return try await link(
      Session(
        peripheralID: camera.peripheralID, displayName: camera.displayName,
        modelHint: camera.advertisedModelHint, rememberedCameras: remembered),
      pairing: true, token: advertisement.token)
  }

  func reconnect(_ camera: SavedCamera) async throws {
    guard let saved = try await store.cameras().first(where: { $0.id == camera.id }),
      saved.peripheralID == camera.peripheralID, saved.model == camera.model,
      saved.peerKeyReference == camera.peerKeyReference
    else { throw WirelessFailure.peerMismatch }
    if let session, session.camera == saved, session.authenticated, session.closing == nil { return }
    _ = try await link(
      Session(
        peripheralID: saved.peripheralID, displayName: saved.displayName, modelHint: saved.model,
        rememberedCameras: [], camera: saved),
      pairing: false, token: store.peerKey(for: saved))
  }

  func identity(for id: WirelessCameraID) async throws -> WirelessIdentity {
    guard let session, let camera = session.camera, session.authenticated, session.closing == nil else {
      throw WirelessFailure.connectionLost
    }
    guard camera.id == id else { throw WirelessFailure.peerMismatch }
    return WirelessIdentity(cameraID: id, model: camera.model, firmware: session.firmware)
  }

  func activateWiFi(for id: WirelessCameraID) async throws -> CameraNetwork {
    guard let session, session.closing == nil, session.authenticated else {
      throw WirelessFailure.connectionLost
    }
    guard session.camera?.id == id else { throw WirelessFailure.peerMismatch }
    guard pending == nil else { throw WirelessFailure.connectionLost }
    let result = try await operation(timeout: WirelessLimits.wifiReadiness, stage: .wifiReadiness) {
      continuation in
      pending = .wifi(continuation)
      advance(.activateWiFi, sessionID: session.id)
    }
    guard case .network(let network) = result else { throw WirelessFailure.unavailableStorage }
    return network
  }

  func events() async -> AsyncStream<BluetoothGatewayEvent> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<BluetoothGatewayEvent>.makeStream(
      bufferingPolicy: .bufferingNewest(16))
    continuation.onTermination = { [weak self] _ in
      Task { @MainActor in self?.eventContinuations.removeValue(forKey: id) }
    }
    eventContinuations[id] = continuation
    if availability != .unknown { continuation.yield(.availability(availability)) }
    return stream
  }

  func disconnect() async {
    finishDiscovery()
    advertisements.removeAll()
    guard session != nil else { return }
    await withCheckedContinuation { continuation in
      disconnectWaiters.append(continuation)
      closeSession(CancellationError())
    }
  }

  private func link(
    _ created: Session, pairing: Bool, token: WirelessProtocolPeerKey?
  ) async throws -> SavedCamera {
    guard session == nil else { throw WirelessFailure.connectionLost }
    try Task.checkCancellation()
    try driver.start(allowPermissionPrompt: pairing)
    if let failure = availability.failure { throw failure }
    finishDiscovery()
    advertisements.removeAll()
    let result = try await operation(
      timeout: pairing ? WirelessLimits.firstPairing : WirelessLimits.savedReconnect,
      stage: pairing ? .firstPairing : .savedReconnect
    ) { continuation in
      session = created
      pending = .link(continuation, pairing: pairing, token: token)
      if availability == .poweredOn {
        driver.connect(peripheralID: created.peripheralID, session: created.id)
      }
    }
    guard case .linked(let camera) = result else { throw WirelessFailure.authentication }
    return camera
  }

  private func operation(
    timeout delay: Duration, stage: WirelessTimeoutStage, begin: (Continuation) -> Void
  ) async throws -> Result {
    let id = UUID()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        operationID = id
        timeout = Task { [weak self] in
          do { try await Task.sleep(for: delay) } catch { return }
          guard self?.operationID == id else { return }
          self?.closeSession(WirelessFailure.timeout(stage), reportIfLinked: true)
        }
        begin(continuation)
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard self?.operationID == id else { return }
        self?.closeSession(CancellationError())
      }
    }
  }

  private func receive(_ event: BluetoothDriverEvent) {
    switch event {
    case .availability(let value):
      let initialPowerOn = availability != .poweredOn && value == .poweredOn
      if availability != value {
        availability = value
        publish(.availability(value))
      }
      if initialPowerOn {
        if discovery != nil { driver.scan() }
        if let session, session.closing == nil, !session.authenticated {
          driver.connect(peripheralID: session.peripheralID, session: session.id)
        }
      } else if let failure = value.failure {
        finishDiscovery(throwing: failure)
        closeSession(failure, reportIfLinked: true)
      }
    case .discovered(let camera, let token):
      guard let discovery, advertisements.count < 64 || advertisements[camera.peripheralID] != nil
      else { return }
      advertisements[camera.peripheralID] = Advertisement(camera: camera, token: token)
      let cameras = advertisements.values.map(\.camera).sorted {
        if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
        return $0.peripheralID.uuidString < $1.peripheralID.uuidString
      }
      discovery.continuation.yield(cameras)
    case .peerModel(let id, let model):
      guard session?.id == id, session?.profile == nil else { return }
      session?.peerModel = model
    case .linkFailed(let id, let failure):
      guard session?.id == id else { return }
      closeSession(failure, reportIfLinked: true)
    case .protocolEvent(let id, let event):
      advance(event, sessionID: id)
    case .disconnected(let id, let failure):
      guard let session, session.id == id else { return }
      self.session = nil
      let error = session.closing?.error ?? failure
      if session.closing?.reportIfLinked != false, session.authenticated, let camera = session.camera {
        publish(.disconnected(camera.id, error as? WirelessFailure ?? failure))
      }
      complete(.failure(error))
      let waiters = disconnectWaiters
      disconnectWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }
  }

  private func advance(_ event: BLEProtocolEvent, sessionID: UUID) {
    guard let active = session, active.id == sessionID, active.closing == nil else { return }
    do {
      if case .services = event, active.profile == nil {
        try prepareProfile(for: active)
      }
      guard let actions = try session?.profile?.receive(event), let camera = session?.camera else {
        return
      }
      for action in actions {
        switch action {
        case .authenticated(let firmware):
          guard case .link(_, let pairing, let token) = pending else { return }
          let saved = pairing
            ? try store.savePaired(camera, peerKey: camera.model == .xe3 ? token : nil) : camera
          session?.camera = saved
          session?.firmware = firmware
          session?.authenticated = true
          complete(.success(.linked(saved)))
        case .wifiReady(let credentials):
          guard case .wifi = pending else { return }
          let reference = try store.savePassword(credentials.password, for: camera.id)
          complete(.success(.network(CameraNetwork(
            ssid: credentials.ssid, security: .wpaPersonal, credential: reference, isHidden: true))))
        default:
          driver.perform(action, session: sessionID)
        }
      }
    } catch {
      closeSession(error, reportIfLinked: true)
    }
  }

  private func prepareProfile(for active: Session) throws {
    guard case .link(_, let pairing, let token) = pending else { return }
    let model: WirelessCameraModel
    if let reported = active.peerModel {
      guard let observed = WirelessCameraModel(rawValue: reported) else {
        throw WirelessFailure.unsupportedProtocol
      }
      if let hint = active.modelHint, observed != hint { throw WirelessFailure.peerMismatch }
      model = observed
    } else if let hint = active.modelHint {
      model = hint
    } else {
      throw BluetoothPairingFailure.unresolvedModel
    }

    switch model {
    case .xt5:
      guard token == nil else { throw WirelessFailure.peerMismatch }
      session?.profile = XT5BLEProfile()
    case .xe3:
      guard let token else { throw WirelessFailure.authentication }
      session?.profile = XE3BLEProfile(intent: pairing ? .pair(token) : .reconnect(token))
    }
    if active.camera == nil {
      let remembered = active.rememberedCameras.first { $0.model == model }
      session?.camera = SavedCamera(
        id: remembered?.id ?? WirelessCameraID(), peripheralID: active.peripheralID,
        model: model, displayName: active.displayName)
    }
  }

  private func complete(_ result: Swift.Result<Result, Error>) {
    timeout?.cancel()
    timeout = nil
    operationID = nil
    let waiter = pending?.continuation
    pending = nil
    waiter?.resume(with: result)
  }

  private func closeSession(_ error: Error, reportIfLinked: Bool = false) {
    guard let active = session, active.closing == nil else { return }
    session?.closing = (error, reportIfLinked)
    driver.disconnect(session: active.id)
  }

  private func finishDiscovery(throwing failure: WirelessFailure? = nil) {
    guard let current = discovery else { return }
    discovery = nil
    driver.stopScan()
    current.continuation.finish(throwing: failure)
  }

  private func publish(_ event: BluetoothGatewayEvent) {
    for continuation in eventContinuations.values { continuation.yield(event) }
  }
}

