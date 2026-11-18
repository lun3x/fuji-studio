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
    var localEndpoint: NWEndpoint? { get }
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
  private let identityTrace: WirelessIdentityTrace.Observer?
  private var phase = Phase.idle
  private var operation: UUID?
  private var waiter: Waiter?
  private var error: (any Error)?
  private var reachedEOF = false
  private var signals: AsyncStream<Signal>.Continuation?
  private var setupTimer: Task<Void, Never>?
  private var closeWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    driver: any Driver, setupTimeout: Duration = WirelessLimits.tcpSetup,
    identityTrace: WirelessIdentityTrace.Observer? = nil
  ) {
    self.driver = driver
    self.setupTimeout = setupTimeout
    self.identityTrace = identityTrace
  }

  static func connect(
    to endpoint: Endpoint, identityTrace: WirelessIdentityTrace.Observer? = nil
  ) async throws -> NetworkByteChannel {
    let channel = NetworkByteChannel(driver: nativeDriver(for: endpoint), identityTrace: identityTrace)
    try await channel.start()
    return channel
  }

  private static func nativeDriver(for endpoint: Endpoint) -> any Driver {
    #if targetEnvironment(simulator)
    let parameters = connectionParameters(requireWiFi: endpoint.mode != .autoSave)
    #else
    let parameters = connectionParameters()
    #endif
    let connection = NWConnection(to: endpoint.nativeEndpoint, using: parameters)
    return NativeNetworkConnection(connection, reportRefusal: endpoint.mode == .autoSave)
  }

  static func connectAutoSave(
    to address: IPv4Address, deadline: ContinuousClock.Instant,
    makeDriver: @Sendable (Endpoint) -> any Driver = { nativeDriver(for: $0) }
  ) async throws -> NetworkByteChannel {
    let endpoint = Endpoint.autoSave(selectedPeer: address)
    let clock = ContinuousClock()
    // The reference clients allow time for the listener to start after IMPORT.
    let limit = min(deadline, clock.now + .seconds(5))
    var lastFailure = WirelessFailure.timeout(.tcpSetup)
    while true {
      try Task.checkCancellation()
      let remaining = clock.now.duration(to: limit)
      guard remaining > .zero else { throw lastFailure }
      let channel = NetworkByteChannel(
        driver: makeDriver(endpoint), setupTimeout: min(.seconds(1), remaining))
      do {
        try await channel.start()
      } catch let failure as WirelessFailure {
        // start() confirms native cancellation before throwing.
        switch failure {
        case .autoSavePeerUnreachable, .timeout(.tcpSetup):
          lastFailure = failure
          try await clock.sleep(until: min(limit, clock.now + .milliseconds(100)))
          continue
        default: throw failure
        }
      }
      if Task.isCancelled || clock.now >= limit {
        await channel.close()
        try Task.checkCancellation()
        throw WirelessFailure.timeout(.tcpSetup)
      }
      return channel
    }
  }

  static func connectionParameters(requireWiFi: Bool = true) -> NWParameters {
    let parameters = NWParameters.tcp
    if requireWiFi { parameters.requiredInterfaceType = .wifi }
    parameters.prohibitedInterfaceTypes = [.cellular]
    return parameters
  }

  var connectedLocalIPv4Bytes: Data? {
    guard phase == .ready,
          case .hostPort(host: .ipv4(let address), port: _)? = driver.localEndpoint
    else { return nil }
    return address.rawValue
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
        identityTrace?(.init(.tcpConnect, .waiting))
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
      if phase == .connecting {
        identityTrace?(.init(.tcpConnect, .failed, failure: .cancelled))
      }
      if phase != .closing { error = WirelessFailure.connectionLost }
      finishClose()
    case .state(.ready):
      guard phase == .connecting, case .setup(let continuation) = waiter else { return }
      phase = .ready
      setupTimer?.cancel()
      setupTimer = nil
      waiter = nil
      identityTrace?(.init(.tcpConnect, .completed))
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
        if read.isComplete {
          identityTrace?(.init(.socketRead, .endOfStream, bytes: read.data.count))
        } else if read.data.isEmpty {
          identityTrace?(.init(.socketRead, .noData, bytes: 0))
        }
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
    if phase == .connecting {
      identityTrace?(.init(.tcpConnect, .failed, failure: .init(failure)))
    }
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
    identityTrace?(.init(.socketClose, .waiting))
    driver.cancel()
    pending?.fail(failure)
  }

  private func finishClose() {
    identityTrace?(.init(.socketClose, .completed))
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
    _ error: NWError, reason: NWPath.UnsatisfiedReason?, reportRefusal: Bool = false
  ) -> WirelessFailure? {
    if let reason {
      switch reason {
      case .notAvailable, .wifiDenied, .cellularDenied, .vpnInactive: return .routeUnavailable
      case .localNetworkDenied: return .permissionDenied(.localNetwork)
      @unknown default: break
      }
    }
    switch error {
    case .posix(.ECONNREFUSED) where reportRefusal:
      return .autoSavePeerUnreachable
    case .posix(.ENETDOWN), .posix(.ENETUNREACH), .posix(.ENODEV):
      return .routeUnavailable
    default:
      return nil
    }
  }
}

extension NetworkByteChannel.Driver {
  var localEndpoint: NWEndpoint? { nil }
}

private final class NativeNetworkConnection: NetworkByteChannel.Driver {
  private let connection: NWConnection
  private let reportRefusal: Bool
  private let queue = DispatchQueue(label: "com.lun3x.FujiStudio.camera-command")

  init(_ connection: NWConnection, reportRefusal: Bool) {
    self.connection = connection
    self.reportRefusal = reportRefusal
  }

  var localEndpoint: NWEndpoint? { connection.currentPath?.localEndpoint }

  func start(_ handler: @escaping @Sendable (NetworkByteChannel.Event) -> Void) {
    connection.stateUpdateHandler = { [weak connection, reportRefusal] state in
      switch state {
      case .ready:
        handler(.ready)
      case .waiting(let error):
        if let failure = Self.routeFailure(error, on: connection, reportRefusal: reportRefusal) {
          handler(.failed(failure))
        }
      case .failed(let error):
        let failure =
          Self.routeFailure(error, on: connection, reportRefusal: reportRefusal)
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

  private static func routeFailure(
    _ error: NWError, on connection: NWConnection?, reportRefusal: Bool = false
  ) -> WirelessFailure? {
    let path = connection?.currentPath
    let reason = path?.status == .unsatisfied ? path?.unsatisfiedReason : nil
    return NetworkByteChannel.waitingFailure(error, reason: reason, reportRefusal: reportRefusal)
  }

  private static func ioFailure(_ error: NWError, stage: WirelessTimeoutStage) -> WirelessFailure {
    if case .posix(.ETIMEDOUT) = error { return .timeout(stage) }
    return .connectionLost
  }
}
