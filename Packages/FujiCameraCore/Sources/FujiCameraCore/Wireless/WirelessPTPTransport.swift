import Foundation

/// One initialized command connection. A new camera session needs a new channel and transport.
public actor WirelessPTPTransport: PTPTransport {
  public static let maximumMetadataBytes = 16 * 1_024 * 1_024
  public static let maximumObjectsPerStorage: UInt32 = 100_000
  /// Upper bound from the reference implementation. A verified peer may require a smaller request.
  public static let maximumPartialObjectBytes: UInt32 = 1_048_576

  private let channel: any WirelessByteChannel
  private let inactivityTimeout: Duration
  private let identityTrace: WirelessIdentityTrace.Observer?
  private var traceStage: WirelessIdentityTrace.Stage?
  public let partialObjectLimit: UInt32
  private var decoder = FujiWirelessFrameDecoder()
  private var initialized = false
  private var lastTransaction: UInt32?
  private var active: UUID?
  private var terminalError: (any Error)?
  private var closeTask: Task<Void, Never>?
  private(set) var streamingPayloadBufferHighWaterBytes = 0

  public init(
    channel: any WirelessByteChannel,
    inactivityTimeout: Duration = WirelessLimits.transactionInactivity,
    maximumPartialObjectBytes: UInt32 = WirelessPTPTransport.maximumPartialObjectBytes,
    identityTrace: WirelessIdentityTrace.Observer? = nil
  ) {
    self.channel = channel
    self.inactivityTimeout = inactivityTimeout
    self.identityTrace = identityTrace
    partialObjectLimit = min(maximumPartialObjectBytes, Self.maximumPartialObjectBytes)
  }

  public func initialize(_ request: Data) async throws -> Data {
    try ensureIdle()
    guard !initialized else { throw PTPError.invalidParameters }
    try FujiWirelessFrameDecoder.validateInitializationRequest(request)
    let id = beginOperation()
    return try await run(id) { transport in
      transport.waitForTrace(.initializationWrite)
      try await transport.write(request)
      transport.finishTrace()
      transport.waitForTrace(.initializationHeader)
      var reply = try await transport.readExactly(FujiWirelessFrameDecoder.initHeaderBytes)
      let length = try FujiWirelessFrameDecoder.initializationLength(reply)
      transport.waitForTrace(.initializationBody)
      reply.append(try await transport.readExactly(length - reply.count))
      try transport.validateBoundary()
      transport.waitForTrace(.initializationACK)
      try FujiWirelessFrameDecoder.validateInitializationReply(reply)
      transport.finishTrace()
      transport.initialized = true
      return reply
    }
  }

  public func execute(_ command: PTPCommand, data: Data?) async throws -> PTPReply {
    try await transact(command, outgoing: data, expectedBytes: nil, sink: nil).reply
  }

  #if DEBUG
  func executeWithDataPhase(_ command: PTPCommand) async throws -> (PTPReply, Bool) {
    let result = try await transact(command, outgoing: nil, expectedBytes: nil, sink: nil)
    return (result.reply, result.receivedDataContainer)
  }
  #endif

  public func receive(
    _ command: PTPCommand, expectedBytes: UInt64,
    sink: @escaping @Sendable (Data) async throws -> Void
  ) async throws -> PTPReply {
    try await transact(command, outgoing: nil, expectedBytes: expectedBytes, sink: sink).reply
  }

  public func close() async {
    await terminate(PTPError.notConnected)
  }

  private struct TransactionReply: Sendable {
    let reply: PTPReply
    let receivedDataContainer: Bool
  }

  private func transact(
    _ command: PTPCommand, outgoing: Data?, expectedBytes: UInt64?,
    sink: (@Sendable (Data) async throws -> Void)?
  ) async throws -> TransactionReply {
    try ensureIdle()
    guard initialized else { throw PTPError.notConnected }
    if let lastTransaction, command.transactionID <= lastTransaction {
      throw PTPError.invalidParameters
    }
    let encoded = try PTPCodec.encode(command)
    if let outgoing, outgoing.count > Self.maximumMetadataBytes { throw PTPError.payloadTooLarge }
    if let expectedBytes,
      expectedBytes > UInt64(UInt32.max) - UInt64(FujiWirelessFrameDecoder.headerBytes)
    {
      throw PTPError.payloadTooLarge
    }
    let partialLimit = try validatePartialRequest(command, expectedBytes: expectedBytes)
    let inventory = InventoryShape(command)
    guard sink == nil || inventory == nil else { throw PTPError.invalidParameters }

    let id = beginOperation()
    let result: Result<TransactionReply, PTPError> = try await run(id) { transport in
      let stages = transport.identityTrace.map { _ in TraceCommand(command) }
      transport.lastTransaction = command.transactionID
      transport.waitForTrace(stages?.write)
      try await transport.write(encoded)
      transport.finishTrace()
      if let outgoing {
        var container = FujiWirelessFrameDecoder.dataHeader(
          length: outgoing.count, command: command)
        container.append(outgoing)
        try await transport.write(container)
      }

      transport.waitForTrace(stages?.header)
      var (header, bytes) = try await transport.readHeader(for: command)
      var payload = Data()
      var receivedBytes: UInt64 = 0
      let receivedDataContainer = header.type == 2
      if receivedDataContainer {
        transport.waitForTrace(stages?.data)
        guard outgoing == nil else { throw PTPError.unexpectedContainerType(header.type) }
        receivedBytes = UInt64(header.payloadLength)
        let limit = expectedBytes ?? UInt64(Self.maximumMetadataBytes)
        guard receivedBytes <= limit, receivedBytes <= partialLimit ?? limit else {
          throw PTPError.payloadTooLarge
        }
        if let expectedBytes, receivedBytes != expectedBytes { throw PTPError.truncatedContainer }
        if let sink {
          try await transport.stream(header.payloadLength, to: sink)
        } else {
          payload = try await transport.readMetadata(header.payloadLength, inventory: inventory)
        }
        transport.waitForTrace(stages?.finalHeader)
        (header, bytes) = try await transport.readHeader(for: command)
        guard header.type == 3 else { throw PTPError.unexpectedContainerType(header.type) }
      }
      transport.waitForTrace(stages?.responseBody)
      bytes.append(try await transport.readExactly(header.payloadLength))
      try transport.validateBoundary()
      do {
        let reply = try PTPCodec.decode(
          response: bytes, data: payload, for: command, maximumDataBytes: Self.maximumMetadataBytes)
        if let expectedBytes, receivedBytes != expectedBytes { throw PTPError.truncatedContainer }
        if inventory != nil, payload.isEmpty { throw PTPError.truncatedContainer }
        if command.opcode == 0x1006 {
          guard let count = reply.parameters.first else { throw PTPError.truncatedContainer }
          guard count <= Self.maximumObjectsPerStorage else { throw PTPError.payloadTooLarge }
        }
        transport.finishTrace()
        return .success(.init(reply: reply, receivedDataContainer: receivedDataContainer))
      } catch let PTPError.responseCode(code) {
        transport.finishTrace(failure: .rejected)
        // A complete, correlated rejection consumed its response. The socket is synchronized.
        return .failure(.responseCode(code))
      }
    }
    return try result.get()
  }

  private func validatePartialRequest(_ command: PTPCommand, expectedBytes: UInt64?) throws
    -> UInt64?
  {
    // GetPartialObject(handle, UInt32 offset, UInt32 maximumBytes).
    guard command.opcode == 0x101b else { return nil }
    guard command.parameters.count == 3 else { throw PTPError.invalidParameters }
    let offset = command.parameters[1]
    let count = command.parameters[2]
    guard count > 0, count <= partialObjectLimit, !offset.addingReportingOverflow(count).overflow,
      (expectedBytes ?? 0) <= UInt64(count)
    else { throw PTPError.invalidParameters }
    return UInt64(count)
  }

  private func readHeader(for command: PTPCommand) async throws -> (
    FujiWirelessFrameDecoder.Header, Data
  ) {
    var bytes = try await readExactly(4)
    let length = FujiWirelessFrameDecoder.length(bytes)
    if length == 8 {
      if try await readExactly(4) == Data(repeating: 0xff, count: 4) {
        throw PTPError.notConnected
      }
    }
    guard length >= FujiWirelessFrameDecoder.headerBytes else {
      throw PTPError.invalidContainerLength
    }
    bytes.append(try await readExactly(FujiWirelessFrameDecoder.headerBytes - bytes.count))
    return (try FujiWirelessFrameDecoder.header(bytes, for: command), bytes)
  }

  private enum InventoryShape {
    case count, handles

    init?(_ command: PTPCommand) {
      if command.opcode == 0x1007
        || (command.opcode == 0x1015 && command.parameters.first == 0xd621)
      {
        self = .handles
      } else if command.opcode == 0x1015 && command.parameters.first == 0xd620 {
        self = .count
      } else {
        return nil
      }
    }
  }

  private func readMetadata(_ length: Int, inventory: InventoryShape?) async throws -> Data {
    guard let inventory else { return try await readExactly(length) }
    guard length >= 4 else { throw PTPError.truncatedContainer }
    var payload = try await readExactly(4)
    let count = FujiWirelessFrameDecoder.uint32(payload, 0)
    guard count <= Self.maximumObjectsPerStorage else { throw PTPError.payloadTooLarge }
    // The count limit bounds this arithmetic and the buffer before requesting the rest.
    let expected = 4 + (inventory == .handles ? Int(count) * 4 : 0)
    guard length >= expected else { throw PTPError.truncatedContainer }
    guard length == expected else { throw PTPError.invalidContainerLength }
    payload.append(try await readExactly(length - 4))
    return payload
  }

  private func stream(_ length: Int, to sink: @Sendable (Data) async throws -> Void) async throws {
    var remaining = length
    while remaining > 0 {
      try await fillBuffer()
      let chunk = decoder.take(min(decoder.availableBytes, remaining))
      streamingPayloadBufferHighWaterBytes = max(
        streamingPayloadBufferHighWaterBytes, chunk.heldBytes)
      remaining -= chunk.bytes.count
      try await sink(chunk.bytes)
      try ensureActive()
    }
  }

  private func readExactly(_ count: Int) async throws -> Data {
    var bytes = Data()
    while bytes.count < count {
      try await fillBuffer()
      bytes.append(decoder.take(min(decoder.availableBytes, count - bytes.count)).bytes)
    }
    return bytes
  }

  private func fillBuffer() async throws {
    guard decoder.availableBytes == 0 else { return }
    if let traceStage {
      identityTrace?(.init(traceStage, .readRequested, bytes: FujiWirelessFrameDecoder.maximumReadBytes))
    }
    let bytes = try await io { [channel] in
      try await channel.read(maximumBytes: FujiWirelessFrameDecoder.maximumReadBytes)
    }
    if let traceStage {
      identityTrace?(.init(traceStage, bytes.isEmpty ? .endOfStream : .readCompleted, bytes: bytes.count))
    }
    guard !bytes.isEmpty else { throw PTPError.truncatedContainer }
    try decoder.supply(bytes)
  }

  private func write(_ data: Data) async throws {
    try await io { [channel] in try await channel.write(data) }
  }

  private func validateBoundary() throws {
    // A command is sent only after this response. Even a partial next frame is unsolicited.
    guard decoder.availableBytes == 0 else { throw PTPError.invalidContainerLength }
  }

  private func ensureIdle() throws {
    try Task.checkCancellation()
    guard terminalError == nil else { throw PTPError.notConnected }
    guard active == nil else { throw PTPError.busy }
  }

  private func ensureActive() throws {
    try Task.checkCancellation()
    if let terminalError { throw terminalError }
  }

  private func beginOperation() -> UUID {
    let id = UUID()
    active = id
    return id
  }

  private func run<Value: Sendable>(
    _ id: UUID, operation: (isolated WirelessPTPTransport) async throws -> Value
  ) async throws -> Value {
    defer { active = nil }
    return try await withTaskCancellationHandler {
      do {
        try ensureActive()
        let value = try await operation(self)
        try ensureActive()
        return value
      } catch {
        let failure = Task.isCancelled ? CancellationError() : terminalError ?? error
        await terminate(failure)
        throw failure
      }
    } onCancel: {
      Task { await self.cancel(id) }
    }
  }

  private func io<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws
    -> Value
  {
    try ensureActive()
    let timer = Task {
      do { try await Task.sleep(for: inactivityTimeout) } catch { return }
      await terminate(WirelessFailure.timeout(.transactionInactivity))
    }
    defer { timer.cancel() }
    let value = try await operation()
    try ensureActive()
    return value
  }

  private func cancel(_ id: UUID) async {
    guard active == id else { return }
    await terminate(CancellationError())
  }

  private func terminate(_ failure: any Error) async {
    if let closeTask {
      await closeTask.value
      return
    }
    if traceStage != nil {
      finishTrace(failure: .init(failure))
    }
    terminalError = failure
    decoder = FujiWirelessFrameDecoder()
    let channel = self.channel
    let cleanup = Task { await channel.close() }
    closeTask = cleanup
    await cleanup.value
  }

  nonisolated func observeIdentity(_ event: @autoclosure () -> WirelessIdentityTrace.Event) {
    identityTrace?(event())
  }

  private func waitForTrace(_ stage: WirelessIdentityTrace.Stage?) {
    guard let identityTrace, let stage else { return }
    traceStage = stage
    identityTrace(.init(stage, .waiting))
  }

  private func finishTrace(failure: WirelessIdentityTrace.Failure? = nil) {
    guard let stage = traceStage, let identityTrace else { return }
    traceStage = nil
    identityTrace(.init(stage, failure == nil ? .completed : .failed, failure: failure))
  }

  private struct TraceCommand {
    typealias Stage = WirelessIdentityTrace.Stage
    let write, header, data, finalHeader, responseBody: Stage

    init(_ command: PTPCommand) {
      (write, header, data, finalHeader, responseBody) = switch (command.opcode, command.parameters.first) {
      case (0x1002, _):
        (.openSessionWrite, .openSessionHeader, .openSessionData, .openSessionFinalHeader, .openSessionResponseBody)
      case (0x1001, _):
        (.getDeviceInfoWrite, .getDeviceInfoHeader, .getDeviceInfoData, .getDeviceInfoFinalHeader, .getDeviceInfoResponseBody)
      case (0x1003, _):
        (.closeSessionWrite, .closeSessionHeader, .closeSessionData, .closeSessionFinalHeader, .closeSessionResponseBody)
      case (0x1015, 0xd212):
        (.xAppEventsRead, .xAppEventsRead, .xAppEventsRead, .xAppEventsRead, .xAppEventsRead)
      case (0x1015, 0xdf24):
        (.xAppVersionRead, .xAppVersionRead, .xAppVersionRead, .xAppVersionRead, .xAppVersionRead)
      default:
        (.otherCommand, .otherCommand, .otherCommand, .otherCommand, .otherCommand)
      }
    }
  }
}
