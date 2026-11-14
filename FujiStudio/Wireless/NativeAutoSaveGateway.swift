import Foundation
import FujiCameraCore
import Network

actor NativeAutoSaveGateway: AutoSaveGateway {
  private enum Outcome: Sendable {
    case registered(AutoSaveRegistration, SavedCamera)
    case session(any WirelessTransferSession)
  }

  private let store: any AutoSaveRegistrationStore
  private let entitlementAvailable: Bool
  private let verifiedIdentity: @Sendable (SavedCamera) async throws -> WirelessProtocolPeerKey?
  private let exchange: AutoSaveExchange
  private let makeSession: AutoSaveSessionFactory
  private let sleep: @Sendable (Duration) async throws -> Void
  private var attempt: Task<Outcome, any Error>?
  private var pendingSession: (any WirelessTransferSession)?
  private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

  /// The production route remains gated until the physical signing and evidence steps pass.
  init(store: any AutoSaveRegistrationStore, clientGUID: Data) {
    self.init(
      store: store, entitlementAvailable: false, verifiedIdentity: { _ in nil },
      exchange: NativeAutoSaveNetwork.exchange,
      makeSession: { address, identity in
        guard let peer = IPv4Address(address) else { throw WirelessFailure.malformedData }
        let channel = try await NetworkByteChannel.connect(to: .autoSave(selectedPeer: peer))
        return AutoSaveTransferAdapter.makeSession(
          transport: .init(channel: channel), expectedIdentity: identity, clientGUID: clientGUID)
      })
  }

  init(
    store: any AutoSaveRegistrationStore, entitlementAvailable: Bool,
    verifiedIdentity: @escaping @Sendable (SavedCamera) async throws -> WirelessProtocolPeerKey?,
    exchange: @escaping AutoSaveExchange, makeSession: @escaping AutoSaveSessionFactory,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.store = store
    self.entitlementAvailable = entitlementAvailable
    self.verifiedIdentity = verifiedIdentity
    self.exchange = exchange
    self.makeSession = makeSession
    self.sleep = sleep
  }

  func register(
    camera: SavedCamera, onRegistered: @escaping @Sendable () async throws -> Void
  ) async throws -> AutoSaveRegistration {
    try checkAvailability()
    guard camera.model == .xe3 else { throw WirelessFailure.unsupportedProtocol }
    let result = try await run(stage: .autoSaveRegistration, limit: WirelessLimits.autoSaveRegistration) {
      deadline in
      guard let key = try await self.verifiedIdentity(camera), key.bytes.count == 32 else {
        throw WirelessFailure.autoSaveIdentityUnavailable
      }
      try Task.checkCancellation()
      // A fresh destination token prevents a stale transfer from satisfying a new setup.
      let importer = "FujiStudio-\(UUID().uuidString.lowercased())"
      let registration = try await self.exchange(.registration, importer, nil, deadline)
      try Task.checkCancellation()
      try await onRegistered()
      let receipt = AutoSaveRegistration(
        cameraID: camera.id, peerKey: key, importer: importer, cameraName: registration.cameraName)
      let session = try await self.openSession(registration: receipt, deadline: deadline)
      try await self.closePendingSession(session)
      return .registered(receipt, camera)
    }
    guard case .registered(let receipt, _) = result else { throw WirelessFailure.connectionLost }
    return receipt
  }

  func savedRegistration(for cameraID: WirelessCameraID) async throws -> AutoSaveRegistration {
    try checkAvailability()
    guard let registration = try await store.autoSaveRegistration(for: cameraID) else {
      throw WirelessFailure.autoSaveRegistrationRequired
    }
    return registration
  }

  func waitForSession(registration: AutoSaveRegistration) async throws -> any WirelessTransferSession {
    try checkAvailability()
    let result = try await run(stage: .autoSaveSession, limit: WirelessLimits.autoSaveSession) { deadline in
      let saved = try await self.savedRegistration(for: registration.cameraID)
      guard saved == registration else { throw WirelessFailure.autoSaveRegistrationRequired }
      let session = try await self.openSession(registration: saved, deadline: deadline)
      // Selection, forget or re-registration can race an asynchronous native wait.
      let current = try await self.savedRegistration(for: registration.cameraID)
      guard current == saved else { throw WirelessFailure.autoSaveRegistrationRequired }
      return .session(session)
    }
    guard case .session(let session) = result else { throw WirelessFailure.connectionLost }
    return session
  }

  func cancel() async {
    guard let attempt else { return }
    attempt.cancel()
    await withCheckedContinuation { cancellationWaiters.append($0) }
  }

  func checkAvailability() throws {
    try Task.checkCancellation()
    guard entitlementAvailable else { throw WirelessFailure.autoSaveEntitlementUnavailable }
  }

  private func openSession(
    registration: AutoSaveRegistration, deadline: ContinuousClock.Instant
  ) async throws -> any WirelessTransferSession {
    try Task.checkCancellation()
    let handshake = try await exchange(.transfer, registration.importer, registration.cameraName, deadline)
    try Task.checkCancellation()
    guard handshake.cameraName == registration.cameraName else { throw WirelessFailure.peerMismatch }
    let expected = WirelessIdentity(
      cameraID: registration.cameraID, model: .xe3, firmware: nil, protocolPeerKey: registration.peerKey)
    let session = try await makeSession(handshake.address, expected)
    pendingSession = session
    try Task.checkCancellation()
    let observed = try await session.open()
    try Task.checkCancellation()
    guard observed.cameraID == expected.cameraID, observed.model == expected.model,
      observed.protocolPeerKey == expected.protocolPeerKey
    else { throw WirelessFailure.peerMismatch }
    guard WirelessSupportPolicy().assess(model: observed.model.rawValue, firmware: observed.firmware)
      == .supported(.xe3)
    else { throw WirelessFailure.unsupportedFirmware }
    return session
  }

  private func closePendingSession(_ session: any WirelessTransferSession) async throws {
    try await session.close()
    pendingSession = nil
  }

  private func run(
    stage: WirelessTimeoutStage, limit: Duration,
    operation: @escaping @Sendable (ContinuousClock.Instant) async throws -> Outcome
  ) async throws -> Outcome {
    guard attempt == nil, pendingSession == nil else { throw WirelessFailure.cameraBusy }
    let deadline = ContinuousClock.now + limit
    let task = Task {
      let outcome = try await withThrowingTaskGroup(of: Outcome.self) { group in
        group.addTask { try await operation(deadline) }
        group.addTask { [sleep] in
          try await sleep(limit)
          throw WirelessFailure.timeout(stage)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
      }
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else { throw WirelessFailure.timeout(stage) }
      if case .registered(let receipt, let camera) = outcome {
        try await store.saveAutoSaveRegistration(receipt, for: camera)
      }
      return outcome
    }
    attempt = task
    defer {
      attempt = nil
      let waiting = cancellationWaiters
      cancellationWaiters.removeAll()
      for waiter in waiting { waiter.resume() }
    }
    do {
      let result = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      try Task.checkCancellation()
      guard !task.isCancelled else { throw CancellationError() }
      pendingSession = nil // Handed off to the coordinator.
      return result
    } catch {
      if let pendingSession { try await closePendingSession(pendingSession) }
      if Task.isCancelled || task.isCancelled { throw CancellationError() }
      if let failure = error as? WirelessFailure {
        switch failure {
        case .timeout(.autoSaveRegistration), .timeout(.autoSaveSession):
          throw WirelessFailure.timeout(stage)
        default: break
        }
      }
      throw error
    }
  }
}
