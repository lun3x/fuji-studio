import Foundation

/// A public ImageCaptureCore session and one bounded wire transaction at a time.
/// Use SerialCameraGate around whole upload/convert/download operations, not around individual commands.
@MainActor public final class SessionCommandTransport: CameraSessionTransport {
  private struct Opening {
    let id: UUID
    let continuation: CheckedContinuation<Void, Error>
    var timeout: UUID?
  }
  private struct Transaction {
    let id: UUID
    let command: PTPCommand
    let continuation: CheckedContinuation<PTPReply, Error>
    let timeout: UUID
  }
  private let driver: any CameraSessionDriver
  private let timeouts: any CameraTimeoutScheduling
  private let timeout: Duration
  private let maximumDataBytes: Int
  private var generation: UInt64 = 0
  private var session: CameraSession?
  private var opening: Opening?
  private var transaction: Transaction?
  private var closing = false
  private var closeID: UUID?
  private var state: CameraState = .disconnected
  private var subscribers: [UUID: AsyncStream<CameraState>.Continuation] = [:]

  public init(
    driver: any CameraSessionDriver,
    timeouts: any CameraTimeoutScheduling = CameraTimeoutScheduler(),
    timeout: Duration = .seconds(30), maximumDataBytes: Int = PTPCodec.maximumDataBytes
  ) {
    self.driver = driver
    self.timeouts = timeouts
    self.timeout = timeout
    self.maximumDataBytes = maximumDataBytes
  }

  public func states() async -> AsyncStream<CameraState> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<CameraState>.makeStream(
      bufferingPolicy: .bufferingNewest(16))
    subscribers[id] = continuation
    continuation.yield(state)
    continuation.onTermination = { [weak self] _ in
      Task { @MainActor in self?.subscribers[id] = nil }
    }
    return stream
  }

  /// Read-only integration boundary. Lifecycle owners must still serialize reconnect with whole
  /// camera operations; this snapshot is not an atomic expected-generation execution primitive.
  public func currentSession() throws -> CameraSession {
    guard let session, !closing else { throw PTPError.notConnected }
    return session
  }

  public func connect() async throws {
    try Task.checkCancellation()
    guard !closing else { throw PTPError.sessionClosing }
    if session != nil { return }
    guard opening == nil else { throw PTPError.busy }
    generation += 1
    let current = generation
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        // Human authorization has no USB deadline. The driver explicitly reports when
        // permission is resolved and actual discovery begins.
        opening = Opening(id: id, continuation: continuation, timeout: nil)
        driver.start { [weak self] event in self?.receive(event, generation: current) }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard let self, self.opening?.id == id else { return }
        self.invalidate(CancellationError(), state: .disconnected)
      }
    }
  }

  private struct CloseWait {
    let id: UUID
    let deadline: UUID
    let continuation: CheckedContinuation<Void, Error>
  }
  private var closeWait: CloseWait?

  /// Lifecycle owners wait for the driver's authoritative acknowledgement. The bounded
  /// wait can fail, but it never clears the transport's uncertain-close quarantine.
  public func disconnectAndWaitForConfirmation() async throws {
    try Task.checkCancellation()
    invalidate(PTPError.notConnected, state: .disconnected)
    guard closing else { return }
    guard closeWait == nil else { throw PTPError.busy }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let deadline = timeouts.schedule(after: timeout) { [weak self] in
          guard let self, self.closeWait?.id == id else { return }
          self.finishCloseWait(.failure(PTPError.timeout))
        }
        closeWait = CloseWait(id: id, deadline: deadline, continuation: continuation)
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard let self, self.closeWait?.id == id else { return }
        self.finishCloseWait(.failure(CancellationError()))
      }
    }
  }
  private func finishCloseWait(_ result: Result<Void, Error>) {
    guard let pending = closeWait else { return }
    closeWait = nil
    timeouts.cancel(pending.deadline)
    pending.continuation.resume(with: result)
  }

  public func close() async throws { try await disconnectAndWaitForConfirmation() }

  public func disconnect() async { invalidate(PTPError.notConnected, state: .disconnected) }

  public func execute(_ command: PTPCommand, data: Data?) async throws -> PTPReply {
    try Task.checkCancellation()
    guard let session, !closing else { throw PTPError.notConnected }
    guard transaction == nil else { throw PTPError.busy }
    guard (data?.count ?? 0) <= maximumDataBytes else { throw PTPError.payloadTooLarge }
    let encoded = try PTPCodec.encode(command)
    let id = UUID()
    let current = session.generation
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let deadline = timeouts.schedule(after: timeout) { [weak self] in
          guard let self, self.transaction?.id == id else { return }
          self.invalidate(PTPError.timeout, state: .recoverableError(.timeout))
        }
        transaction = Transaction(
          id: id, command: command, continuation: continuation, timeout: deadline)
        publish(.busy(session))
        driver.send(command: encoded, data: data) { [weak self] result in
          self?.receive(result, id: id, generation: current)
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard let self, self.transaction?.id == id else { return }
        self.invalidate(CancellationError(), state: .disconnected)
      }
    }
  }

  private func receive(_ event: CameraDriverEvent, generation current: UInt64) {
    guard current == generation, !closing else { return }
    switch event {
    case .authorizationRequired: publish(.authorizationRequired)
    case .discoveryStarted:
      guard let pending = opening, pending.timeout == nil else { return }
      let id = pending.id
      let deadline = timeouts.schedule(after: timeout) { [weak self] in
        guard let self, self.opening?.id == id else { return }
        self.invalidate(PTPError.timeout, state: .recoverableError(.timeout))
      }
      guard opening?.id == id else {
        timeouts.cancel(deadline)
        return
      }
      opening?.timeout = deadline
      publish(.discovering)
    case .opening: publish(.opening)
    case .opened(let connection):
      guard let pending = opening else { return }
      opening = nil
      if let deadline = pending.timeout { timeouts.cancel(deadline) }
      let opened = CameraSession(generation: current, connection: connection)
      session = opened
      publish(.sessionOpen(opened))
      pending.continuation.resume()
    case .removed: invalidate(PTPError.notConnected, state: .disconnected)
    case .failed(let error):
      let state: CameraState
      switch error {
      case .authorizationDenied: state = .authorizationDenied
      case .wrongMode(let reason): state = .wrongMode(reason)
      default: state = .recoverableError(error)
      }
      invalidate(error, state: state)
    }
  }

  private func receive(
    _ result: Result<PTPWireReply, PTPError>, id: UUID, generation current: UInt64
  ) {
    guard current == generation, !closing, let pending = transaction, pending.id == id else {
      return
    }
    do {
      let wire = try result.get()
      let reply: PTPReply
      switch wire.correlation {
      case .directWireTransaction:
        reply = try PTPCodec.decode(
          response: wire.response, data: wire.data, for: pending.command,
          maximumDataBytes: maximumDataBytes)
      case .imageCaptureCoreCallback(let echoedCommand):
        reply = try PTPCodec.decodeFrameworkManaged(
          response: wire.response, data: wire.data, for: pending.command,
          echoedCommand: echoedCommand, maximumDataBytes: maximumDataBytes)
      }

      transaction = nil
      timeouts.cancel(pending.timeout)
      if let session { publish(.sessionOpen(session)) }
      pending.continuation.resume(returning: reply)
    } catch let error as PTPError {
      // A complete, identified camera rejection does not leave a wire operation active.
      if case .responseCode = error {
        transaction = nil
        timeouts.cancel(pending.timeout)
        if let session { publish(.sessionOpen(session)) }
        pending.continuation.resume(throwing: error)
      } else {
        invalidate(error, state: .recoverableError(error))
      }
    } catch {
      invalidate(
        PTPError.sessionFailure(String(describing: error)),
        state: .recoverableError(.sessionFailure(String(describing: error))))
    }
  }

  private func invalidate(_ error: any Error, state newState: CameraState) {
    // Invalidate identity BEFORE resuming a caller or asking the framework to close.
    // A resumed operation may release the external gate, but execute remains unavailable.
    generation += 1
    session = nil
    if let pending = opening {
      opening = nil
      if let deadline = pending.timeout { timeouts.cancel(deadline) }
      pending.continuation.resume(throwing: error)
    }
    if let pending = transaction {
      transaction = nil
      timeouts.cancel(pending.timeout)
      pending.continuation.resume(throwing: error)
    }
    publish(newState)
    guard !closing else { return }
    closing = true
    let closeID = UUID()
    self.closeID = closeID
    driver.close { [weak self] in
      guard let self else { return }
      // Repeated disconnects do not make an unconfirmed old close available.
      guard self.closeID == closeID else { return }
      self.closeID = nil
      self.closing = false
      self.finishCloseWait(.success(()))
    }
  }
  private func publish(_ value: CameraState) {
    state = value
    for continuation in subscribers.values { continuation.yield(value) }
  }
}
