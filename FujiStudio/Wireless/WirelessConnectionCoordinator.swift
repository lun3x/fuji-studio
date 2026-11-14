@preconcurrency import CoreBluetooth
import Foundation
import FujiCameraCore

typealias WirelessTransferSessionFactory = @Sendable (WirelessIdentity, JoinedCameraNetwork)
  async throws -> any WirelessTransferSession

actor WirelessConnectionCoordinator {
  private enum Work {
    case discovery
    case pair(DiscoveredCamera)
    case reconnect(SavedCamera, prompt: Bool)
  }

  private struct WiFiRequest {
    let intent: WirelessConnectionIntent
    var waiter: CheckedContinuation<WirelessConnectionIntent, Error>?
  }

  private let bluetooth: any BluetoothGateway
  private let store: any SavedCameraStore
  private let authorization: @Sendable () -> WirelessBluetoothAuthorization
  private let wifi: (any WiFiJoinGateway)?
  private let ownership: (any WirelessCameraOwnershipGateway)?
  private let sessionFactory: WirelessTransferSessionFactory?
  private let sleep: @Sendable (Duration) async throws -> Void

  private var snapshot = WirelessConnectionState() {
    didSet {
      guard snapshot != oldValue else { return }
      for observer in observers.values { observer.yield(snapshot) }
    }
  }
  private var observers: [UUID: AsyncStream<WirelessConnectionState>.Continuation] = [:]
  private var savedLoaded = false
  private var loading: (id: UUID, task: Task<Void, Never>)?
  private var mutatingStore = false

  private var work: (id: UUID, kind: Work, task: Task<Void, Never>)?
  private var cleanup: Task<Void, Never>?
  private var pendingDiscovery: UUID?
  private var eventListener: (id: UUID, task: Task<Void, Never>)?
  private var terminalDuringLink: WirelessFailure?
  private var gatewayUsed = false
  private var retry: (id: UUID, task: Task<Void, Never>)?
  private var backoffIndex = 0
  private static let retryDelays: [Duration] = [.seconds(3), .seconds(6), .seconds(12), .seconds(30)]
  private var blockedFailure: WirelessFailure?

  private var wifiRequest: WiFiRequest?
  private var activeTransfer: WirelessConnectionIntent?
  private var wifiAttempt: (id: UUID, task: Task<Void, Never>)?
  private var wifiTeardown: Task<Void, Never>?
  private var wifiLease: CameraUseLease?
  private var joinedNetwork: JoinedCameraNetwork?
  private var session: (any WirelessTransferSession)?
  private var cameraWiFiActivationStarted = false

  init(
    bluetooth: any BluetoothGateway, store: any SavedCameraStore,
    authorization: @escaping @Sendable () -> WirelessBluetoothAuthorization = {
      switch CBManager.authorization {
      case .allowedAlways: .allowed
      case .notDetermined: .notDetermined
      default: .denied
      }
    },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    wifi: (any WiFiJoinGateway)? = nil, ownership: (any WirelessCameraOwnershipGateway)? = nil,
    sessionFactory: WirelessTransferSessionFactory? = nil
  ) {
    self.bluetooth = bluetooth
    self.store = store
    self.authorization = authorization
    self.sleep = sleep
    self.wifi = wifi
    self.ownership = ownership
    self.sessionFactory = sessionFactory
  }

  func states() -> AsyncStream<WirelessConnectionState> {
    let id = UUID()
    let (stream, observer) = AsyncStream<WirelessConnectionState>.makeStream(bufferingPolicy: .bufferingNewest(1))
    observers[id] = observer
    observer.onTermination = { [weak self] _ in
      Task { await self?.removeObserver(id) }
    }
    observer.yield(snapshot)
    return stream
  }

  func setActivity(_ activity: WirelessActivity) async {
    guard snapshot.activity != activity else { return }
    snapshot.activity = activity
    switch activity {
    case .active:
      await loadSavedCameras()
      startAutomaticReconnect()
    case .inactive:
      break
    case .background:
      await resetConnection()
      startAutomaticReconnect()
    }
  }

  func select(_ id: WirelessCameraID) async throws {
    try await withSavedCameraMutation {
      guard id != snapshot.selectedCameraID else { return }
      guard snapshot.savedCameras.contains(where: { $0.id == id }) else {
        throw WirelessFailure.peerMismatch
      }
      await resetConnection()
      guard wifiLease == nil else { throw WirelessFailure.cameraBusy }
      try await store.select(id)
      blockedFailure = nil
      snapshot.selectedCameraID = id
      clearFailures()
    }
  }

  func forget(_ id: WirelessCameraID) async throws {
    try await withSavedCameraMutation {
      let isSelected = snapshot.selectedCameraID == id
      // A pending pair can target a remembered camera even if it was unselected.
      if isSelected || isPairing || pendingDiscovery != nil {
        await resetConnection()
      }
      guard !isSelected || wifiLease == nil else { throw WirelessFailure.cameraBusy }
      try await store.forget(id)
      snapshot.savedCameras.removeAll { $0.id == id }
      if isSelected {
        snapshot.selectedCameraID = nil
        blockedFailure = nil
        clearFailures()
      }
    }
  }

  func startDiscovery() async {
    guard snapshot.activity != .background, !mutatingStore, cleanup == nil,
      activeTransfer == nil, wifiRequest == nil, wifiAttempt == nil, wifiLease == nil, pendingDiscovery == nil
    else { return }
    if case .discovery = work?.kind { return }
    let id = UUID()
    pendingDiscovery = id
    defer {
      if pendingDiscovery == id { pendingDiscovery = nil }
    }
    await loadSavedCameras()
    guard pendingDiscovery == id, !Task.isCancelled else { return }
    await resetConnection(preservingDiscovery: id)
    guard pendingDiscovery == id, !Task.isCancelled, !mutatingStore, cleanup == nil,
      activeTransfer == nil, wifiRequest == nil, wifiLease == nil, work == nil
    else { return }
    clearFailures()
    guard authorization() != .denied else {
      recordBluetoothFailure(.permissionDenied(.bluetooth))
      return
    }
    snapshot.bluetooth = .discovering
    begin(.discovery)
  }

  func pair(_ camera: DiscoveredCamera) {
    guard snapshot.activity != .background, !mutatingStore, activeTransfer == nil,
      case .discovery = work?.kind, snapshot.discoveredCameras.contains(camera)
    else { return }
    // Pair uses the gateway's cached advertisement. A full disconnect would discard it.
    work?.task.cancel()
    loading = nil
    snapshot.connectionGeneration &+= 1
    snapshot.discoveredCameras = []
    snapshot.bluetooth = .pairing
    clearFailures()
    begin(.pair(camera))
  }

  func retryBluetooth() async {
    await loadSavedCameras()
    guard snapshot.activity != .background, !mutatingStore, cleanup == nil, pendingDiscovery == nil,
      work == nil, activeTransfer == nil, wifiLease == nil, snapshot.bluetooth != .ready
    else { return }
    cancelRetry()
    blockedFailure = nil
    clearFailures()
    startReconnect(prompt: true)
  }

  /// Call after acquiring exclusive camera ownership. The native WiFi stages belong
  /// to the holder of the returned intent and must check it across suspension points.
  func prepareWiFiConnection() async throws -> WirelessConnectionIntent {
    await loadSavedCameras()
    try Task.checkCancellation()
    guard snapshot.activity != .background else { throw CancellationError() }
    guard let camera = selectedCamera else { throw WirelessFailure.peerMismatch }
    guard !mutatingStore, cleanup == nil, wifiRequest == nil, activeTransfer == nil, pendingDiscovery == nil,
      !isPairing, snapshot.bluetooth != .discovering
    else { throw WirelessFailure.cameraBusy }

    snapshot.connectionGeneration &+= 1
    let intent = WirelessConnectionIntent(cameraID: camera.id, connectionGeneration: snapshot.connectionGeneration)
    let prepared: WirelessConnectionIntent = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { waiter in
        wifiRequest = WiFiRequest(intent: intent, waiter: waiter)
        snapshot.wifiFailure = nil
        snapshot.wifiFailurePhase = nil
        snapshot.wifi = .waitingForBluetooth
        if snapshot.bluetooth == .ready {
          satisfyWiFiRequest()
        } else if work == nil {
          cancelRetry()
          blockedFailure = nil
          clearFailures()
          startReconnect(prompt: true)
        }
      }
    } onCancel: {
      Task { await self.finishWiFiConnection(intent) }
    }
    guard !Task.isCancelled, isCurrent(prepared) else {
      finishWiFiConnection(intent)
      throw CancellationError()
    }
    return prepared
  }

  func isCurrent(_ intent: WirelessConnectionIntent) -> Bool {
    wifiRequest?.intent == intent && snapshot.activity != .background
  }

  func finishWiFiConnection(_ intent: WirelessConnectionIntent) {
    guard isCurrent(intent) else { return }
    endWiFiRequest()
  }

  /// An old transfer still owns its lock until its pause or cancellation completes.
  func setTransferActive(_ active: Bool, for intent: WirelessConnectionIntent) throws {
    if active {
      guard isCurrent(intent), snapshot.wifi == .ready || snapshot.wifi == .bluetoothReady else { throw CancellationError() }
      guard activeTransfer == nil || activeTransfer == intent else { throw WirelessFailure.cameraBusy }
      activeTransfer = intent
    } else if activeTransfer == intent {
      activeTransfer = nil
      startAutomaticReconnect()
    }
  }

  func cancelConnection() async {
    if wifiAttempt != nil || wifiTeardown != nil || wifiLease != nil {
      await disconnectWiFi()
    } else if wifiRequest != nil {
      endWiFiRequest()
    } else if pendingDiscovery != nil || isPairing || snapshot.bluetooth == .discovering || isExplicitReconnect {
      await resetConnection()
      await loadSavedCameras()
      startAutomaticReconnect()
    }
  }

  private var selectedCamera: SavedCamera? {
    snapshot.savedCameras.first { $0.id == snapshot.selectedCameraID }
  }

  private var isPairing: Bool {
    if case .pair = work?.kind { return true }
    return false
  }

  private var isExplicitReconnect: Bool {
    if case .reconnect(_, prompt: true) = work?.kind { return true }
    return false
  }


  private func loadSavedCameras() async {
    guard !savedLoaded else { return }
    if let cleanup { await cleanup.value }
    guard !savedLoaded, !isPairing, cleanup == nil else { return }
    if let loading {
      await loading.task.value
      return
    }
    let id = UUID()
    let task = Task { await readSavedCameras(id: id) }
    loading = (id, task)
    await task.value
  }

  private func readSavedCameras(id: UUID) async {
    defer {
      if loading?.id == id { loading = nil }
    }
    do {
      let cameras = try await store.cameras()
      guard loading?.id == id else { return }
      let selected = try await store.selected()
      guard loading?.id == id, !isPairing, cleanup == nil else { return }
      snapshot.savedCameras = cameras
      snapshot.selectedCameraID = cameras.first { $0.id == selected }?.id
      savedLoaded = true
    } catch {
      guard loading?.id == id, !isPairing, cleanup == nil else { return }
      snapshot.failure = (error as? WirelessFailure) ?? .unavailableStorage
    }
  }

  private func withSavedCameraMutation(_ body: () async throws -> Void) async throws {
    await loadSavedCameras()
    guard !mutatingStore, activeTransfer == nil else { throw WirelessFailure.cameraBusy }
    mutatingStore = true
    defer {
      mutatingStore = false
      startAutomaticReconnect()
    }
    do {
      try await body()
    } catch {
      await loadSavedCameras()
      throw error
    }
    await loadSavedCameras()
  }

  private func startAutomaticReconnect() {
    guard snapshot.activity == .active, !mutatingStore, cleanup == nil, activeTransfer == nil, pendingDiscovery == nil,
      wifiAttempt == nil, wifiTeardown == nil, wifiLease == nil,
      work == nil, savedLoaded, retry == nil, blockedFailure == nil, snapshot.bluetooth != .ready
    else { return }
    startReconnect(prompt: false)
  }

  private func startReconnect(prompt: Bool) {
    guard let camera = selectedCamera else { return }
    let permission = authorization()
    guard permission == .allowed || (permission == .notDetermined && prompt) else {
      recordBluetoothFailure(.permissionDenied(.bluetooth))
      return
    }
    snapshot.bluetooth = .connecting
    begin(.reconnect(camera, prompt: prompt))
  }

  private func begin(_ kind: Work) {
    let id = UUID()
    let bluetooth = self.bluetooth
    eventListener?.task.cancel()
    eventListener = nil
    terminalDuringLink = nil
    let task = Task { [weak self] in
      let events = await bluetooth.events()
      guard await self?.listen(to: events, id: id) == true else { return }
      do {
        try Task.checkCancellation()
        switch kind {
        case .discovery:
          let candidates = try await bluetooth.discover()
          for try await cameras in candidates {
            await self?.receiveDiscovery(cameras, id: id)
          }
          await self?.finishDiscovery(id: id)
        case .pair(let candidate):
          let camera = try await bluetooth.pair(candidate)
          await self?.finishPairing(camera, id: id)
        case .reconnect(let camera, let prompt):
          try await bluetooth.reconnect(camera, allowPermissionPrompt: prompt)
          await self?.finishReconnect(id: id)
        }
      } catch {
        await self?.workFailed(error, id: id)
      }
    }
    work = (id, kind, task)
  }

  private func listen(to events: AsyncStream<BluetoothGatewayEvent>, id: UUID) -> Bool {
    guard work?.id == id else { return false }
    gatewayUsed = true
    let task = Task { [weak self] in
      for await event in events { await self?.receive(event, id: id) }
    }
    eventListener = (id, task)
    return true
  }

  private func receive(_ event: BluetoothGatewayEvent, id: UUID) {
    guard eventListener?.id == id else { return }
    guard case .disconnected(let cameraID, let failure) = event else { return }
    if work?.id == id {
      terminalDuringLink = failure
    } else if snapshot.bluetooth == .ready, snapshot.selectedCameraID == cameraID {
      recordBluetoothFailure(failure)
      scheduleRetry()
    }
  }

  private func receiveDiscovery(_ cameras: [DiscoveredCamera], id: UUID) {
    guard work?.id == id else { return }
    snapshot.discoveredCameras = cameras
  }

  private func finishDiscovery(id: UUID) {
    guard work?.id == id else { return }
    work = nil
    snapshot.discoveredCameras = []
    snapshot.bluetooth = .idle
  }

  private func finishPairing(_ camera: SavedCamera, id: UUID) async {
    guard work?.id == id else { return }
    // The gateway has already persisted these credentials, regardless of selection.
    if let index = snapshot.savedCameras.firstIndex(where: { $0.id == camera.id }) {
      snapshot.savedCameras[index] = camera
    } else {
      snapshot.savedCameras.append(camera)
    }
    let previousSelection: WirelessCameraID?
    let savedCameras: [SavedCamera]
    do {
      if let failure = terminalDuringLink { throw failure }
      if savedLoaded {
        previousSelection = snapshot.selectedCameraID
        savedCameras = snapshot.savedCameras
      } else {
        let persistedCameras = try await store.cameras()
        guard work?.id == id else { return }
        previousSelection = try await store.selected()
        // Preserve the exact record returned by the pairing operation.
        savedCameras = persistedCameras.contains { $0.id == camera.id }
          ? persistedCameras.map { $0.id == camera.id ? camera : $0 }
          : persistedCameras + [camera]
      }
      guard work?.id == id else { return }
      try Task.checkCancellation()
    } catch {
      await failPairSelection(error, id: id)
      return
    }
    do {
      try await store.select(camera.id)
    } catch {
      if work?.id == id {
        await failPairSelection(error, id: id)
      } else {
        await store.restoreSelection(previousSelection, replacing: camera.id)
      }
      return
    }
    guard work?.id == id else {
      await store.restoreSelection(previousSelection, replacing: camera.id)
      return
    }
    snapshot.savedCameras = savedCameras
    snapshot.selectedCameraID = camera.id
    savedLoaded = true
    finishReconnect(id: id)
  }

  private func failPairSelection(_ error: Error, id: UUID) async {
    guard work?.id == id else { return }
    // Pair has already authenticated. Close that link if persistence failed.
    work = nil
    recordBluetoothFailure((error as? WirelessFailure) ?? .unavailableStorage)
    await resetConnection()
  }

  private func finishReconnect(id: UUID) {
    guard work?.id == id else { return }
    if let failure = terminalDuringLink {
      workFailed(failure, id: id)
      return
    }
    work = nil
    backoffIndex = 0
    blockedFailure = nil
    snapshot.bluetooth = .ready
    snapshot.failure = nil
    satisfyWiFiRequest()
  }

  private func workFailed(_ error: Error, id: UUID) {
    guard let current = work, current.id == id else { return }
    work = nil
    snapshot.discoveredCameras = []
    if let pairingFailure = error as? BluetoothPairingFailure {
      snapshot.pairingFailure = pairingFailure
      snapshot.bluetooth = .unavailable
      return
    }
    let failure = (error as? WirelessFailure) ?? .unavailableStorage
    recordBluetoothFailure(failure)
    if case .reconnect = current.kind { scheduleRetry() }
  }

  private func recordBluetoothFailure(_ failure: WirelessFailure) {
    if wifiRequest != nil, !cameraWiFiActivationStarted { endWiFiRequest(failure: failure) }
    switch failure {
    case .connectionLost, .timeout, .cameraBusy:
      snapshot.bluetooth = .waitingForCamera
      snapshot.failure = nil
    default:
      blockedFailure = failure
      snapshot.bluetooth = .unavailable
      snapshot.failure = failure
    }
  }

  private func scheduleRetry() {
    guard snapshot.activity == .active, activeTransfer == nil, wifiLease == nil, blockedFailure == nil else { return }
    let id = UUID()
    let delay = Self.retryDelays[backoffIndex]
    backoffIndex = min(backoffIndex + 1, Self.retryDelays.count - 1)
    let sleep = self.sleep
    let task = Task { [weak self] in
      do { try await sleep(delay) } catch { return }
      await self?.retryDue(id)
    }
    retry = (id, task)
  }

  private func retryDue(_ id: UUID) {
    guard retry?.id == id else { return }
    retry = nil
    startAutomaticReconnect()
  }

  private func cancelRetry() {
    retry?.task.cancel()
    retry = nil
  }

  private func satisfyWiFiRequest() {
    guard let current = wifiRequest, let waiter = current.waiter else { return }
    wifiRequest?.waiter = nil
    snapshot.wifi = .bluetoothReady
    waiter.resume(returning: current.intent)
  }

  private func endWiFiRequest(failure: WirelessFailure? = nil) {
    guard let current = wifiRequest else { return }
    wifiRequest = nil
    snapshot.connectionGeneration &+= 1
    snapshot.wifi = .idle
    snapshot.wifiFailure = failure
    if let failure {
      current.waiter?.resume(throwing: failure)
    } else {
      current.waiter?.resume(throwing: CancellationError())
    }
  }

  private func resetConnection(preservingDiscovery id: UUID? = nil) async {
    if pendingDiscovery != id { pendingDiscovery = nil }
    await disconnectWiFi()
    snapshot.connectionGeneration &+= 1
    endWiFiRequest()
    if wifiLease == nil {
      snapshot.wifiFailure = nil
      snapshot.wifiFailurePhase = nil
    }
    cancelRetry()
    backoffIndex = 0
    let pending = work
    if isPairing {
      savedLoaded = false
      loading = nil
    }
    work = nil
    pending?.task.cancel()
    eventListener?.task.cancel()
    eventListener = nil
    snapshot.discoveredCameras = []
    snapshot.bluetooth = blockedFailure == nil ? .idle : .unavailable
    snapshot.failure = blockedFailure
    if let cleanup {
      await cleanup.value
    } else if gatewayUsed || pending != nil {
      let bluetooth = self.bluetooth
      let task = Task {
        await bluetooth.disconnect()
        await pending?.task.value
        cleanup = nil
      }
      gatewayUsed = false
      cleanup = task
      await task.value
    }
  }

  private func clearFailures() {
    snapshot.failure = nil
    snapshot.wifiFailure = nil
    snapshot.wifiFailurePhase = nil
    snapshot.pairingFailure = nil
  }

  private func removeObserver(_ id: UUID) { observers[id] = nil }
}

extension WirelessConnectionCoordinator {
  func connectWiFi() async {
    guard let wifi, let ownership, let sessionFactory else {
      snapshot.wifiFailure = .unsupportedProtocol
      return
    }
    guard !Task.isCancelled, snapshot.activity == .active, !mutatingStore,
      wifiAttempt == nil, wifiTeardown == nil, wifiLease == nil, wifiRequest == nil,
      activeTransfer == nil, pendingDiscovery == nil, !isPairing, snapshot.bluetooth != .discovering
    else { return }
    snapshot.wifiFailure = nil
    snapshot.wifiFailurePhase = nil
    snapshot.wifi = .acquiringOwnership
    let id = UUID()
    let attempt = Task { await runWiFi(id, wifi: wifi, ownership: ownership, makeSession: sessionFactory) }
    wifiAttempt = (id, attempt)
    await withTaskCancellationHandler {
      await attempt.value
    } onCancel: {
      Task { await self.cancelWiFi(id) }
    }
  }

  func disconnectWiFi() async {
    if let wifiTeardown { await wifiTeardown.value; return }
    guard wifiAttempt != nil || wifiLease != nil else { return }
    let previous = wifiAttempt?.task
    previous?.cancel()
    endWiFiRequest()
    snapshot.wifi = .disconnecting
    await teardownWiFi(waitingFor: previous)
  }

  func transferSession() async throws -> any WirelessTransferSession {
    guard snapshot.wifi == .ready, snapshot.activity != .background, let session else {
      throw WirelessFailure.connectionLost
    }
    return session
  }

  private func cancelWiFi(_ id: UUID) async {
    guard wifiAttempt?.id == id else { return }
    await disconnectWiFi()
  }

  private func runWiFi(
    _ id: UUID, wifi: any WiFiJoinGateway, ownership: any WirelessCameraOwnershipGateway,
    makeSession: WirelessTransferSessionFactory
  ) async {
    do {
      wifiLease = try await ownership.acquireWireless()
      try checkWiFiAttempt(id)
      let intent = try await prepareWiFiConnection()
      try checkWiFiAttempt(id, intent)
      snapshot.wifi = .activatingCamera
      let bleIdentity = try await bluetooth.identity(for: intent.cameraID)
      try checkWiFiAttempt(id, intent)
      guard bleIdentity.cameraID == intent.cameraID, bleIdentity.model == selectedCamera?.model else {
        throw WirelessFailure.peerMismatch
      }
      // The Bluetooth gateway owns the positive readiness result. A link event can arrive
      // before its continuation resumes when a body drops BLE as the access point starts.
      cameraWiFiActivationStarted = true
      let cameraNetwork = try await bluetooth.activateWiFi(for: intent.cameraID)
      try checkWiFiAttempt(id, intent)
      guard cameraNetwork.credential.cameraID == intent.cameraID else { throw WirelessFailure.peerMismatch }
      snapshot.wifi = .joiningNetwork
      let joined = try await wifi.join(cameraNetwork)
      joinedNetwork = joined
      try checkWiFiAttempt(id, intent)
      try await wifi.verify(joined)
      try checkWiFiAttempt(id, intent)
      snapshot.wifi = .openingSession
      let opened = try await makeSession(bleIdentity, joined)
      session = opened
      try checkWiFiAttempt(id, intent)
      let peer = try await opened.open()
      try checkWiFiAttempt(id, intent)
      snapshot.wifi = .checkingFirmware
      guard peer.cameraID == bleIdentity.cameraID, peer.model == bleIdentity.model else {
        throw WirelessFailure.peerMismatch
      }
      try await wifi.verify(joined)
      try checkWiFiAttempt(id, intent)
      let policy = WirelessSupportPolicy()
      guard policy.assess(model: peer.model.rawValue, firmware: peer.firmware) == .supported(peer.model),
        bleIdentity.firmware == nil
          || policy.assess(model: peer.model.rawValue, firmware: bleIdentity.firmware)
            == .supported(peer.model)
      else { throw WirelessFailure.unsupportedFirmware }
      snapshot.wifi = .loadingInventory
      let stream = try await opened.enumerate()
      try checkWiFiAttempt(id, intent)
      for try await batch in stream {
        try checkWiFiAttempt(id, intent)
        if !batch.objects.isEmpty || batch.storageChanges.values.contains(.complete) {
          snapshot.wifi = .ready
          return
        }
      }
      throw WirelessFailure.unavailableStorage
    } catch {
      guard wifiTeardown == nil else { return }
      let phase = snapshot.wifi
      let cancellation = Task.isCancelled || error is CancellationError
      let failure = cancellation ? nil : (error as? WirelessFailure) ?? .connectionLost
      endWiFiRequest(failure: failure)
      snapshot.wifiFailure = failure
      snapshot.wifiFailurePhase = failure == nil ? nil : phase
      snapshot.wifi = .disconnecting
      await teardownWiFi(waitingFor: nil)
    }
  }

  private func checkWiFiAttempt(_ id: UUID, _ intent: WirelessConnectionIntent? = nil) throws {
    try Task.checkCancellation()
    guard wifiAttempt?.id == id, snapshot.activity != .background,
      intent.map(isCurrent) ?? true
    else { throw CancellationError() }
  }

  private func teardownWiFi(waitingFor previous: Task<Void, Never>?) async {
    let cleanup = Task {
      // Close an in-progress socket first so its pending native I/O can finish.
      let earlySession = self.session
      var confirmed = await confirmClose(earlySession)
      await previous?.value
      if earlySession == nil { confirmed = await confirmClose(session) }
      await wifi?.drainPendingJoin()
      if let joinedNetwork {
        await wifi?.leave(joinedNetwork)
        self.joinedNetwork = nil
      }
      if confirmed, let wifiLease {
        await ownership?.releaseWireless(wifiLease)
        self.wifiLease = nil
      }
      wifiAttempt = nil
      wifiTeardown = nil
      cameraWiFiActivationStarted = false
      snapshot.wifi = .idle
      startAutomaticReconnect()
    }
    wifiTeardown = cleanup
    await cleanup.value
  }

  private func confirmClose(_ target: (any WirelessTransferSession)?) async -> Bool {
    guard let target else { return true }
    do {
      try await target.close()
      session = nil
      return true
    } catch {
      snapshot.wifiFailure = (error as? WirelessFailure) ?? .connectionLost
      snapshot.wifiFailurePhase = .disconnecting
      return false
    }
  }
}
