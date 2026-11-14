import Foundation
import FujiCameraCore
import Network

/// Opens only endpoints supplied by a recognized camera mode. The caller owns Wi-Fi association
/// and peer identity checks before adopting the command connection as a transfer session.
actor NetworkByteChannel: WirelessByteChannel {
  struct Endpoint: Sendable {
    private static let commandPort: NWEndpoint.Port = 55_740
    let mode: WirelessMode
    let address: IPv4Address
    let port = commandPort

    private init(mode: WirelessMode, address: IPv4Address) {
      self.mode = mode
      self.address = address
    }

    static func cameraHosted(mode: WirelessMode) throws -> Self {
      guard mode == .xApp || mode == .phone else { throw WirelessFailure.unsupportedProtocol }
      return Self(mode: mode, address: IPv4Address("192.168.0.1")!)
    }

    /// The address comes from the selected AutoSave peer's discovery/registration.
    static func autoSave(selectedPeer: IPv4Address) -> Self {
      Self(mode: .autoSave, address: selectedPeer)
    }

    fileprivate var nativeEndpoint: NWEndpoint { .hostPort(host: .ipv4(address), port: port) }
  }

  struct Read: Sendable {
    let data: Data
    let isComplete: Bool
  }

  enum Event: Sendable {
    case ready
    case failed(WirelessFailure)
    case cancelled
  }

  protocol Driver: Sendable {
    func start(_ handler: @escaping @Sendable (Event) -> Void)
    func read(
      maximumBytes: Int, completion: @escaping @Sendable (Result<Read, WirelessFailure>) -> Void)
    func write(
      _ data: Data, completion: @escaping @Sendable (Result<Void, WirelessFailure>) -> Void)
    func cancel()
  }

  private enum Phase { case idle, connecting, ready, closing, closed }

  private enum Signal: Sendable {
    case state(Event)
    case read(UUID, Result<Read, WirelessFailure>)
    case write(UUID, Result<Void, WirelessFailure>)
  }

  private enum Waiter {
    case setup(CheckedContinuation<Void, any Error>)
    case read(Int, CheckedContinuation<Data, any Error>)
    case write(CheckedContinuation<Void, any Error>)

    func fail(_ error: any Error) {
      switch self {
      case .setup(let continuation), .write(let continuation): continuation.resume(throwing: error)
      case .read(_, let continuation): continuation.resume(throwing: error)
      }
    }
  }

  private let driver: any Driver
  private let setupTimeout: Duration
  private var phase = Phase.idle
  private var operation: UUID?
  private var waiter: Waiter?
  private var error: (any Error)?
  private var reachedEOF = false
  private var signals: AsyncStream<Signal>.Continuation?
  private var setupTimer: Task<Void, Never>?
  private var closeWaiters: [CheckedContinuation<Void, Never>] = []

  init(driver: any Driver, setupTimeout: Duration = WirelessLimits.tcpSetup) {
    self.driver = driver
    self.setupTimeout = setupTimeout
  }

  static func connect(to endpoint: Endpoint) async throws -> NetworkByteChannel {
    let connection = NWConnection(to: endpoint.nativeEndpoint, using: connectionParameters())
    let channel = NetworkByteChannel(driver: NativeNetworkConnection(connection))
    try await channel.start()
    return channel
  }

  static func connectionParameters() -> NWParameters {
    let parameters = NWParameters.tcp
    parameters.requiredInterfaceType = .wifi
    parameters.prohibitedInterfaceTypes = [.cellular]
    return parameters
  }

  func start() async throws {
    guard phase == .idle else { throw error ?? PTPError.busy }
    do {
      try await perform { (_, continuation: CheckedContinuation<Void, any Error>) in
        phase = .connecting
        waiter = .setup(continuation)
        let (stream, signals) = AsyncStream<Signal>.makeStream()
        self.signals = signals
        // Ordered delivery for both Network callbacks and their pending I/O completions.
        Task { [weak self] in
          for await signal in stream { await self?.handle(signal) }
        }
        setupTimer = Task { [weak self, setupTimeout] in
          do { try await Task.sleep(for: setupTimeout) } catch { return }
          await self?.setupExpired()
        }
        driver.start { signals.yield(.state($0)) }
      }
    } catch {
      await close()
      throw error
    }
  }

  func read(maximumBytes: Int) async throws -> Data {
    try Task.checkCancellation()
    guard phase == .ready, let signals else { throw error ?? WirelessFailure.connectionLost }
    guard maximumBytes > 0 else { throw PTPError.invalidParameters }
    if reachedEOF { return Data() }
    let limit = min(maximumBytes, 65_536)
    return try await perform { id, continuation in
      waiter = .read(limit, continuation)
      driver.read(maximumBytes: limit) { signals.yield(.read(id, $0)) }
    }
  }

  func write(_ data: Data) async throws {
    try Task.checkCancellation()
    guard phase == .ready, let signals else { throw error ?? WirelessFailure.connectionLost }
    try await perform { id, continuation in
      waiter = .write(continuation)
      driver.write(data) { signals.yield(.write(id, $0)) }
    }
  }

  func close() async {
    beginClose(WirelessFailure.connectionLost)
    guard phase != .closed else { return }
    await withCheckedContinuation { closeWaiters.append($0) }
  }

  private func perform<Value: Sendable>(
    _ begin: (UUID, CheckedContinuation<Value, any Error>) -> Void
  ) async throws -> Value {
    try Task.checkCancellation()
    guard operation == nil else { throw PTPError.busy }
    let id = UUID()
    operation = id
    defer { operation = nil }
    return try await withTaskCancellationHandler {
      do {
        let value = try await withCheckedThrowingContinuation { begin(id, $0) }
        if Task.isCancelled { throw CancellationError() }
        if let error { throw error }
        return value
      } catch {
        if Task.isCancelled {
          beginClose(CancellationError())
          throw CancellationError()
        }
        throw error
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }

  private func setupExpired() {
    guard phase == .connecting else { return }
    beginClose(WirelessFailure.timeout(.tcpSetup))
  }

  private func cancel(_ id: UUID) {
    guard operation == id else { return }
    beginClose(CancellationError())
  }

  private func handle(_ signal: Signal) {
    switch signal {
    case .state(.cancelled):
      if phase != .closing { error = WirelessFailure.connectionLost }
      finishClose()
    case .state(.ready):
      guard phase == .connecting, case .setup(let continuation) = waiter else { return }
      phase = .ready
      setupTimer?.cancel()
      setupTimer = nil
      waiter = nil
      continuation.resume()
    case .state(.failed(let failure)):
      if phase == .ready, failure == .timeout(.tcpSetup) {
        beginClose(WirelessFailure.timeout(.transactionInactivity))
      } else {
        beginClose(failure)
      }
    case .read(let id, let result):
      guard operation == id, case .read(let limit, let continuation) = waiter else { return }
      switch result {
      case .success(let read):
        guard read.data.count <= limit, read.isComplete || !read.data.isEmpty else {
          beginClose(WirelessFailure.malformedData)
          return
        }
        reachedEOF = read.isComplete
        waiter = nil
        continuation.resume(returning: read.data)
      case .failure(let error):
        beginClose(error)
      }
    case .write(let id, let result):
      guard operation == id, case .write(let continuation) = waiter else { return }
      switch result {
      case .success:
        waiter = nil
        continuation.resume()
      case .failure(let error):
        beginClose(error)
      }
    }
  }

  private func beginClose(_ failure: any Error) {
    guard phase != .closing, phase != .closed else { return }
    error = failure
    if phase == .idle {
      finishClose()
      return
    }
    phase = .closing
    setupTimer?.cancel()
    setupTimer = nil
    let pending = waiter
    waiter = nil
    driver.cancel()
    pending?.fail(failure)
  }

  private func finishClose() {
    phase = .closed
    setupTimer?.cancel()
    setupTimer = nil
    let pending = waiter
    waiter = nil
    pending?.fail(error ?? WirelessFailure.connectionLost)
    signals?.finish()
    signals = nil
    let closing = closeWaiters
    closeWaiters.removeAll()
    for continuation in closing { continuation.resume() }
  }

  static func waitingFailure(
    _ error: NWError, reason: NWPath.UnsatisfiedReason?
  ) -> WirelessFailure? {
    if let reason {
      switch reason {
      case .notAvailable, .wifiDenied, .cellularDenied, .vpnInactive: return .routeUnavailable
      case .localNetworkDenied: return .permissionDenied(.localNetwork)
      @unknown default: break
      }
    }
    switch error {
    case .posix(.ENETDOWN), .posix(.ENETUNREACH), .posix(.ENODEV):
      return .routeUnavailable
    default:
      return nil
    }
  }
}

private final class NativeNetworkConnection: NetworkByteChannel.Driver {
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "com.lun3x.FujiStudio.camera-command")

  init(_ connection: NWConnection) { self.connection = connection }

  func start(_ handler: @escaping @Sendable (NetworkByteChannel.Event) -> Void) {
    connection.stateUpdateHandler = { [weak connection] state in
      switch state {
      case .ready:
        handler(.ready)
      case .waiting(let error):
        if let failure = Self.routeFailure(error, on: connection) { handler(.failed(failure)) }
      case .failed(let error):
        let failure =
          Self.routeFailure(error, on: connection)
          ?? Self.ioFailure(error, stage: .tcpSetup)
        handler(.failed(failure))
      case .cancelled:
        handler(.cancelled)
      default:
        break
      }
    }
    connection.start(queue: queue)
  }

  func read(
    maximumBytes: Int,
    completion: @escaping @Sendable (Result<NetworkByteChannel.Read, WirelessFailure>) -> Void
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: maximumBytes) {
      [weak connection] data, _, isComplete, error in
      if let error {
        completion(
          .failure(
            Self.routeFailure(error, on: connection)
              ?? Self.ioFailure(error, stage: .transactionInactivity)))
      } else {
        completion(.success(.init(data: data ?? Data(), isComplete: isComplete)))
      }
    }
  }

  func write(
    _ data: Data,
    completion: @escaping @Sendable (Result<Void, WirelessFailure>) -> Void
  ) {
    connection.send(
      content: data,
      completion: .contentProcessed { [weak connection] error in
        if let error {
          completion(
            .failure(
              Self.routeFailure(error, on: connection)
                ?? Self.ioFailure(error, stage: .transactionInactivity)))
        } else {
          completion(.success(()))
        }
      })
  }

  func cancel() { connection.cancel() }

  private static func routeFailure(_ error: NWError, on connection: NWConnection?)
    -> WirelessFailure?
  {
    let path = connection?.currentPath
    let reason = path?.status == .unsatisfied ? path?.unsatisfiedReason : nil
    return NetworkByteChannel.waitingFailure(error, reason: reason)
  }

  private static func ioFailure(_ error: NWError, stage: WirelessTimeoutStage) -> WirelessFailure {
    if case .posix(.ETIMEDOUT) = error { return .timeout(stage) }
    return .connectionLost
  }
}
