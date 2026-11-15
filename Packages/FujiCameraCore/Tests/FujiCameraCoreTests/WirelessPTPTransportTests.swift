import Foundation
import XCTest

@testable import FujiCameraCore

final class WirelessPTPTransportTests: XCTestCase, @unchecked Sendable {
  // Synthetic wire fixtures. Layout follows the pinned libfuji/camlib source.
  // No test uses a packet capture from either target camera.
  private let request =
    Data([
      0x52, 0, 0, 0, 1, 0, 0, 0, 0xf2, 0xe4, 0x53, 0x8f,
      1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
      0x46, 0, 0x75, 0, 0x6a, 0, 0x69, 0,
    ]) + Data(repeating: 0, count: 46)

  private var ack: Data { initialAck(name: [0x58, 0, 0x2d, 0, 0x54, 0, 0x35, 0, 0, 0]) }
  private let command = PTPCommand(opcode: 0x1009, parameters: [42], transactionID: 1)

  func testBuildsSourceDerivedInitRequest() throws {
    XCTAssertEqual(
      try FujiWirelessFrameDecoder.initializationRequest(
        clientName: "Fuji", clientGUID: Data(1...16)), request)
    XCTAssertThrowsError(
      try FujiWirelessFrameDecoder.initializationRequest(
        clientName: String(repeating: "A", count: 27), clientGUID: Data(1...16)))
    XCTAssertThrowsError(
      try FujiWirelessFrameDecoder.initializationRequest(
        clientName: "A\0B", clientGUID: Data(1...16)))
    XCTAssertThrowsError(
      try FujiWirelessFrameDecoder.initializationRequest(
        clientName: "A", clientGUID: Data([1])))
  }

  func testEveryHeaderSplitAndCoalescedDataResponse() async throws {
    let payload = Data([0x11, 0x22, 0x33])
    let data = frame(type: 2, code: 0x1009, payload: payload)
    let response = frame(type: 3, code: 0x2001, payload: word(3))
    for split in 1..<12 {
      let channel = FixtureChannel(reads: [
        ack.prefix(split), ack.dropFirst(split), data.prefix(split),
        data.dropFirst(split) + response,
      ])
      let transport = WirelessPTPTransport(channel: channel)
      let replyAck = try await transport.initialize(request)
      XCTAssertEqual(replyAck, ack)
      let reply = try await transport.execute(command, data: nil)
      XCTAssertEqual(reply.data, payload)
      XCTAssertEqual(reply.parameters, [3])
      XCTAssertEqual(reply.rawResponse, response)
      XCTAssertEqual(reply.wireTransactionID, 1)
      XCTAssertEqual(reply.logicalTransactionID, 1)
      XCTAssertEqual(reply.correlation, .directWireTransaction)
      let writes = await channel.writes
      XCTAssertEqual(
        writes, [request, Data([16, 0, 0, 0, 1, 0, 9, 0x10, 1, 0, 0, 0, 42, 0, 0, 0])])
    }
  }

  func testOneByteReadsAndOutgoingDataContainer() async throws {
    let response = frame(type: 3, code: 0x2001)
    let channel = FixtureChannel(reads: (ack + response).map { Data([$0]) })
    let transport = try await initialized(channel)
    let set = PTPCommand(opcode: 0x1016, parameters: [0xdf21], transactionID: 1)
    let reply = try await transport.execute(set, data: Data([5, 0]))
    XCTAssertTrue(reply.data.isEmpty)
    let writes = await channel.writes
    XCTAssertEqual(
      writes,
      [
        request,
        Data([16, 0, 0, 0, 1, 0, 0x16, 0x10, 1, 0, 0, 0, 0x21, 0xdf, 0, 0]),
        Data([14, 0, 0, 0, 2, 0, 0x16, 0x10, 1, 0, 0, 0, 5, 0]),
      ])
  }

  func testRejectsInvalidInitAckUTF16LengthsTypesAndFailure() async throws {
    let cases: [(Data, PTPError)] = [
      (initialAck(name: [0x58, 0xd8, 0, 0]), .sessionFailure("Invalid Fuji initialization name")),
      (initialAck(name: [0x58, 0]), .sessionFailure("Invalid Fuji initialization name")),
      (initialAck(name: [0, 0, 0x58, 0]), .sessionFailure("Invalid Fuji initialization name")),
      (initialAck(name: [0]), .invalidContainerLength),
      (word(83) + word(2), .oversizedContainer),
      (word(12) + word(6) + word(0), .invalidContainerLength),
      (word(8) + word(6), .invalidContainerLength),
      (word(12) + word(5) + word(1), .authorizationDenied),
      (Data(ack.dropLast()), .truncatedContainer),
    ]
    for (bytes, expected) in cases {
      let channel = FixtureChannel(reads: [bytes])
      let transport = WirelessPTPTransport(channel: channel)
      do {
        _ = try await transport.initialize(request)
        XCTFail("Invalid initialization succeeded")
      } catch {
        XCTAssertEqual(error as? PTPError, expected)
      }
      let closed = await channel.closed
      XCTAssertTrue(closed)
    }
  }

  func testRejectsWrongTypeOpcodeTransactionAndMalformedLengthsBeforeDeliveringData() async throws {
    let goodData = frame(type: 2, code: 0x1009, payload: Data([1]))
    let cases: [(Data, PTPError)] = [
      (frame(type: 1, code: 0x1009), .unexpectedContainerType(1)),
      (frame(type: 2, code: 0x1008, payload: Data([1])), .invalidOpcode(0x1008)),
      (
        frame(type: 2, code: 0x1009, transaction: 11, payload: Data([1])),
        .wrongTransaction(expected: 1, actual: 11)
      ),
      (frame(type: 3, code: 0x2001, transaction: 0), .wrongTransaction(expected: 1, actual: 0)),
      (frame(type: 3, code: 0x1009), .responseCode(0x1009)),
      (word(11), .invalidContainerLength),
      (word(8) + word(.max), .notConnected),
      (frame(type: 3, code: 0x2001, payload: Data([1])), .invalidContainerLength),
      (frame(type: 3, code: 0x2001, payload: Data(repeating: 0, count: 24)), .oversizedContainer),
      (Data(goodData.prefix(8)), .truncatedContainer),
    ]
    for (bytes, expected) in cases {
      let channel = FixtureChannel(reads: [ack, bytes])
      let transport = try await initialized(channel)
      do {
        _ = try await transport.receive(command, expectedBytes: 1) { _ in
          XCTFail("Invalid frame reached sink")
        }
        XCTFail("Invalid frame succeeded")
      } catch {
        XCTAssertEqual(error as? PTPError, expected)
      }
      let closed = await channel.closed
      XCTAssertTrue(closed)
    }
  }

  func testRejectsEarlyResponseForAnUnsentTransaction() async throws {
    let channel = FixtureChannel(reads: [
      ack, frame(type: 3, code: 0x2001) + frame(type: 3, code: 0x2001, transaction: 2),
    ])
    let transport = try await initialized(channel)
    do {
      _ = try await transport.execute(command, data: nil)
      XCTFail("Unsolicited response was accepted")
    } catch {
      XCTAssertEqual(error as? PTPError, .invalidContainerLength)
    }
    let writes = await channel.writes
    XCTAssertEqual(writes.count, 2)
  }

  func testRejectsPreviousTransactionResponseAndClosesSession() async throws {
    let channel = FixtureChannel(reads: [
      ack, frame(type: 3, code: 0x2001), frame(type: 3, code: 0x2001),
    ])
    let transport = try await initialized(channel)
    _ = try await transport.execute(command, data: nil)
    let next = PTPCommand(opcode: 0x1001, parameters: [], transactionID: 2)
    do {
      _ = try await transport.execute(next, data: nil)
      XCTFail("Previous response satisfied successor")
    } catch {
      XCTAssertEqual(error as? PTPError, .wrongTransaction(expected: 2, actual: 1))
    }
    do {
      _ = try await transport.execute(next, data: nil)
      XCTFail("Desynchronized session was reused")
    } catch {
      XCTAssertEqual(error as? PTPError, .notConnected)
    }
    let writes = await channel.writes
    XCTAssertEqual(writes.count, 3)
  }

  func testCompletedCameraErrorAllowsNextTransaction() async throws {
    let channel = FixtureChannel(reads: [
      ack, frame(type: 3, code: 0x2005), frame(type: 3, code: 0x2001, transaction: 2),
    ])
    let transport = try await initialized(channel)
    do {
      _ = try await transport.receive(command, expectedBytes: 20) { _ in
        XCTFail("Error response generated payload")
      }
      XCTFail("Error response succeeded")
    } catch {
      XCTAssertEqual(error as? PTPError, .responseCode(0x2005))
    }
    let reply = try await transport.execute(
      PTPCommand(opcode: 0x1001, parameters: [], transactionID: 2), data: nil)
    XCTAssertEqual(reply.wireTransactionID, 2)
  }

  func testSinkFailureClosesEvenIfItThrowsAResponseCode() async throws {
    let channel = FixtureChannel(reads: [
      ack, frame(type: 2, code: 0x1009, payload: Data([1])) + frame(type: 3, code: 0x2001),
    ])
    let transport = try await initialized(channel)
    do {
      _ = try await transport.receive(command, expectedBytes: 1) { _ in
        throw PTPError.responseCode(0x2005)
      }
      XCTFail("Failed sink produced successful reply")
    } catch {
      XCTAssertEqual(error as? PTPError, .responseCode(0x2005))
    }
    let closed = await channel.closed
    XCTAssertTrue(closed)
  }

  func testRejectsOversizedMetadataAndStreamingBeyondFrozenLengthAtHeader() async throws {
    let metadataLength: UInt32 = 16 * 1024 * 1024 + 1
    let cases: [(Bool, UInt32, PTPError)] = [
      (false, metadataLength, .payloadTooLarge),
      (true, 11, .payloadTooLarge),
      (true, 9, .truncatedContainer),
    ]
    for (stream, length, expected) in cases {
      let channel = FixtureChannel(reads: [
        ack, frame(type: 2, code: 0x1009, declaredLength: 12 + length),
      ])
      let transport = try await initialized(channel)
      do {
        if stream {
          _ = try await transport.receive(command, expectedBytes: 10) { _ in
            XCTFail("Unexpected length reached sink")
          }
        } else {
          _ = try await transport.execute(command, data: nil)
        }
        XCTFail("Invalid payload length succeeded")
      } catch {
        XCTAssertEqual(error as? PTPError, expected)
      }
      let reads = await channel.readCount
      XCTAssertEqual(reads, 2)
    }
  }

  func testRejectsMalformedAndExcessObjectCounts() async throws {
    let cases: [(UInt16, [UInt32], Data, PTPError)] = [
      (0x1007, [1], word(100_001), .payloadTooLarge),
      (0x1007, [1], word(.max), .payloadTooLarge),
      (0x1007, [1], word(2) + word(7), .truncatedContainer),
      (0x1007, [1], word(0) + word(7), .invalidContainerLength),
      (0x1007, [1], Data([0, 0]), .truncatedContainer),
      (0x1015, [0xd620], word(100_001), .payloadTooLarge),
      (0x1015, [0xd621], word(100_001), .payloadTooLarge),
    ]
    for (opcode, parameters, bytes, expected) in cases {
      let channel = FixtureChannel(reads: [
        ack, frame(type: 2, code: opcode, payload: bytes) + frame(type: 3, code: 0x2001),
      ])
      let transport = try await initialized(channel)
      do {
        _ = try await transport.execute(
          .init(opcode: opcode, parameters: parameters, transactionID: 1), data: nil)
        XCTFail("Invalid object count succeeded")
      } catch {
        XCTAssertEqual(error as? PTPError, expected)
      }
      let closed = await channel.closed
      XCTAssertTrue(closed)
    }
  }

  func testAcceptsEmptyObjectInventory() async throws {
    let channel = FixtureChannel(reads: [
      ack, frame(type: 2, code: 0x1007, payload: word(0)) + frame(type: 3, code: 0x2001),
    ])
    let transport = try await initialized(channel)
    let reply = try await transport.execute(
      .init(opcode: 0x1007, parameters: [1], transactionID: 1), data: nil)
    XCTAssertEqual(reply.data, word(0))
  }

  func testRejectsPartialRequestBeyondNegotiatedLimitOrOverflow() async throws {
    let channel = FixtureChannel(reads: [ack])
    let transport = WirelessPTPTransport(channel: channel, maximumPartialObjectBytes: 512)
    _ = try await transport.initialize(request)
    for (parameters, expectedBytes) in [
      ([UInt32(7), 0, 513], UInt64(512)), ([7, .max, 1], 1), ([7, 0, 512], 513),
    ] {
      do {
        _ = try await transport.receive(
          .init(opcode: 0x101b, parameters: parameters, transactionID: 1),
          expectedBytes: expectedBytes
        ) { _ in XCTFail("Invalid request reached sink") }
        XCTFail("Invalid partial request succeeded")
      } catch {
        XCTAssertEqual(error as? PTPError, .invalidParameters)
      }
    }
    let writes = await channel.writes
    let closed = await channel.closed
    XCTAssertEqual(writes, [request])
    XCTAssertFalse(closed)
  }

  func testRejectsRequestedPartialAboveOneMiBRegardlessOfDeviceLimit() async throws {
    let channel = FixtureChannel(reads: [ack])
    let transport = WirelessPTPTransport(channel: channel, maximumPartialObjectBytes: .max)
    _ = try await transport.initialize(request)
    do {
      _ = try await transport.receive(
        .init(opcode: 0x101b, parameters: [7, 0, 1_048_577], transactionID: 1),
        expectedBytes: 1_048_577
      ) { _ in XCTFail("Oversized request reached sink") }
      XCTFail("Oversized partial request succeeded")
    } catch {
      XCTAssertEqual(error as? PTPError, .invalidParameters)
    }
    let writes = await channel.writes
    XCTAssertEqual(writes, [request])
  }

  func testSlowSinkBoundsMemoryAndEOFDoesNotSucceed() async throws {
    let size = 32 * 1024 * 1024
    let gate = SinkGate()
    let coalescedBytes = 65_524
    let initialFrame = frame(
      type: 2, code: 0x1009,
      payload: Data(repeating: 0x33, count: coalescedBytes), declaredLength: UInt32(size + 12))
    let channel = FixtureChannel(
      reads: [ack, initialFrame], generatedBytes: size - 2 * coalescedBytes,
      suffix: Data(repeating: 0x33, count: coalescedBytes) + frame(type: 3, code: 0x2001))
    let transport = try await initialized(channel)
    let transfer = Task {
      try await transport.receive(command, expectedBytes: UInt64(size)) { try await gate.write($0) }
    }
    await gate.waitUntilBlocked()
    let readsAtSink = await channel.readCount
    XCTAssertEqual(readsAtSink, 2)
    try await Task.sleep(for: .milliseconds(30))
    let readsWhileSinkBlocked = await channel.readCount - readsAtSink
    XCTAssertEqual(readsWhileSinkBlocked, 0)
    await gate.release()
    let reply = try await transfer.value
    XCTAssertTrue(reply.data.isEmpty)
    let delivered = await gate.byteCount
    XCTAssertEqual(delivered, size)
    let maximumRead = await channel.maximumRead
    XCTAssertEqual(maximumRead, 65_536)
    let streamingPayloadBufferHighWaterBytes = await transport.streamingPayloadBufferHighWaterBytes
    print("Streaming payload buffer high-water: \(streamingPayloadBufferHighWaterBytes) bytes")
    XCTAssertGreaterThanOrEqual(streamingPayloadBufferHighWaterBytes, 65_536)
    XCTAssertLessThanOrEqual(streamingPayloadBufferHighWaterBytes, 131_072)

    let truncated = FixtureChannel(
      reads: [ack, frame(type: 2, code: 0x1009, payload: Data([1]), declaredLength: 14)])
    let truncatedTransport = try await initialized(truncated)
    var truncatedTransferSuccessCount = 0
    do {
      _ = try await truncatedTransport.receive(command, expectedBytes: 2) { _ in }
      truncatedTransferSuccessCount += 1
    } catch {
      XCTAssertEqual(error as? PTPError, .truncatedContainer)
    }
    XCTAssertEqual(truncatedTransferSuccessCount, 0)
  }

  func testCancellationClosesAndUnblocksPendingReadWithoutAcceptingSuccessor() async throws {
    let channel = FixtureChannel(reads: [ack], suspendAtEnd: true)
    let transport = try await initialized(channel)
    let active = Task { try await transport.execute(command, data: nil) }
    await channel.waitUntilSuspended()
    let next = PTPCommand(opcode: 0x1001, parameters: [], transactionID: 2)
    do {
      _ = try await transport.execute(next, data: nil)
      XCTFail("Overlapping transaction wrote to stream")
    } catch {
      XCTAssertEqual(error as? PTPError, .busy)
    }
    active.cancel()
    do {
      _ = try await active.value
      XCTFail("Canceled read succeeded")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    do {
      _ = try await transport.execute(next, data: nil)
      XCTFail("Canceled channel was reused")
    } catch {
      XCTAssertEqual(error as? PTPError, .notConnected)
    }
    let writes = await channel.writes
    let closed = await channel.closed
    XCTAssertEqual(writes.count, 2)
    XCTAssertTrue(closed)
  }

  func testReadInactivityTimesOutAndClosesChannel() async throws {
    let channel = FixtureChannel(reads: [ack], suspendAtEnd: true)
    let transport = WirelessPTPTransport(channel: channel, inactivityTimeout: .milliseconds(100))
    _ = try await transport.initialize(request)
    do {
      _ = try await transport.execute(command, data: nil)
      XCTFail("Inactive read succeeded")
    } catch {
      XCTAssertEqual(error as? WirelessFailure, .timeout(.transactionInactivity))
    }
    let closed = await channel.closed
    XCTAssertTrue(closed)
  }

  private func initialized(_ channel: FixtureChannel) async throws -> WirelessPTPTransport {
    let transport = WirelessPTPTransport(channel: channel)
    _ = try await transport.initialize(request)
    return transport
  }

  private func initialAck(name: [UInt8]) -> Data {
    word(UInt32(28 + name.count)) + word(2) + Data(repeating: 0, count: 20) + Data(name)
  }

  private func frame(
    type: UInt16, code: UInt16, transaction: UInt32 = 1, payload: Data = Data(),
    declaredLength: UInt32? = nil
  ) -> Data {
    let typeAndCode = word(UInt32(type) | UInt32(code) << 16)
    return word(declaredLength ?? UInt32(12 + payload.count)) + typeAndCode + word(transaction)
      + payload
  }

  private func word(_ value: UInt32) -> Data {
    Data([0, 8, 16, 24].map { UInt8(truncatingIfNeeded: value >> $0) })
  }
}

private actor FixtureChannel: WirelessByteChannel {
  private var reads: [Data]
  private var generatedBytes: Int
  private var suffix: Data
  private let suspendAtEnd: Bool
  private var suspended: CheckedContinuation<Data, Never>?
  private var suspensionObserver: CheckedContinuation<Void, Never>?
  private(set) var closed = false
  private(set) var writes: [Data] = []
  private(set) var readCount = 0
  private(set) var maximumRead = 0

  init(reads: [Data], generatedBytes: Int = 0, suffix: Data = Data(), suspendAtEnd: Bool = false) {
    self.reads = reads
    self.generatedBytes = generatedBytes
    self.suffix = suffix
    self.suspendAtEnd = suspendAtEnd
  }

  func read(maximumBytes: Int) async throws -> Data {
    readCount += 1
    maximumRead = max(maximumRead, maximumBytes)
    guard !closed else { return Data() }
    if !reads.isEmpty {
      let chunk = reads.removeFirst()
      if chunk.count > maximumBytes { reads.insert(Data(chunk.dropFirst(maximumBytes)), at: 0) }
      return Data(chunk.prefix(maximumBytes))
    }
    if generatedBytes > 0 {
      let size = min(maximumBytes, generatedBytes)
      generatedBytes -= size
      return Data(repeating: 0x33, count: size)
    }
    if !suffix.isEmpty {
      let chunk = Data(suffix.prefix(maximumBytes))
      suffix = Data(suffix.dropFirst(maximumBytes))
      return chunk
    }
    guard suspendAtEnd else { return Data() }
    return await withCheckedContinuation { continuation in
      suspended = continuation
      suspensionObserver?.resume()
      suspensionObserver = nil
    }
  }

  func write(_ data: Data) async throws { writes.append(data) }

  func waitUntilSuspended() async {
    guard suspended == nil else { return }
    await withCheckedContinuation { suspensionObserver = $0 }
  }

  func close() async {
    closed = true
    let pending = suspended
    suspended = nil
    pending?.resume(returning: Data())
  }
}

private actor SinkGate {
  private var blocked: CheckedContinuation<Void, Never>?
  private var observer: CheckedContinuation<Void, Never>?
  private(set) var byteCount = 0

  func write(_ data: Data) async throws {
    let shouldBlock = byteCount == 0
    byteCount += data.count
    if shouldBlock {
      await withCheckedContinuation { continuation in
        blocked = continuation
        observer?.resume()
        observer = nil
      }
    }
    XCTAssertTrue(data.allSatisfy { $0 == 0x33 })
  }

  func waitUntilBlocked() async {
    guard blocked == nil else { return }
    await withCheckedContinuation { observer = $0 }
  }

  func release() {
    let continuation = blocked
    blocked = nil
    continuation?.resume()
  }
}
