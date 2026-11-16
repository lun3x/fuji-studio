import Foundation

public enum PhoneTransferAdapter {
  public static func makeSession(
    transport: WirelessPTPTransport, expectedIdentity: WirelessIdentity, clientGUID: Data
  ) -> any WirelessTransferSession {
    CameraHostedTransferSession(
      transport: transport, expectedIdentity: expectedIdentity, mode: .phone, clientGUID: clientGUID)
  }
}

extension CameraHostedTransferSession {
  // Legacy camera-hosted phone gallery subset from libfuji 3b9932a. Remote capture,
  // live view initialization, and their auxiliary sockets are outside this session.
  func configurePhone() async throws -> [UInt32] {
    let clock = ContinuousClock()
    let deadline = clock.now + WirelessLimits.transactionInactivity
    var state: UInt32?
    repeat {
      state = try await readEvents()[0xdf00]
      if state == 0 || state == nil {
        guard clock.now < deadline else { throw WirelessFailure.timeout(.transactionInactivity) }
        try await Task.sleep(for: .milliseconds(100))
      }
    } while state == 0 || state == nil
    guard state == 6 else { throw WirelessFailure.unsupportedProtocol }
    let remote = try await readScalar(0xdf24)
    let gallery = try await readScalar(0xdf25)
    guard (0x20004...0x20006).contains(remote), (1...5).contains(gallery) else {
      throw WirelessFailure.unsupportedProtocol
    }
    try await setProperty(0xdf01, 5, width: 2)
    _ = try await readEvents()
    try await setProperty(0xdf24, 0x2000c, width: 4)
    try await setProperty(0xdf00, 6, width: 2)
    _ = try await readEvents()
    _ = try await readEvents()
    try await setProperty(0xdf01, 11, width: 2)
    _ = try await readEvents()
    try await setProperty(0xdf25, 5, width: 4)
    _ = try await readEvents()
    guard legacyObjectCount != nil else { throw WirelessFailure.unavailableStorage }
    selectedStorage = 0  // The legacy single-card gallery has no slot selection command.
    return [0]
  }

  @discardableResult
  func readEvents(whileClosing: Bool = false) async throws -> [UInt32: UInt32] {
    let data = try await execute(0x1015, [0xd212], whileClosing: whileClosing).data
    guard data.count >= 2 else { throw WirelessFailure.malformedData }
    let count = Int(try Self.scalar(Data(data.prefix(2)), widths: [2]))
    guard count <= 4096 else { throw WirelessFailure.malformedData }
    let fixedSize = 2 + count * 6
    let numericEnd: Int
    if mode == .xApp, count > 0, data.count == fixedSize - 1,
       data.suffix(5) == Data([0x2f, 0xd2, 0x01, 0x00, 0x00]) {
      // The X-T5 XApp gallery can end its event batch with this exact short
      // D22F (DatabaseFilename) record. It has no UInt32 value to return.
      numericEnd = data.count - 5
    } else {
      guard data.count == fixedSize else { throw WirelessFailure.malformedData }
      numericEnd = fixedSize
    }
    var events: [UInt32: UInt32] = [:]
    for offset in stride(from: 2, to: numericEnd, by: 6) {
      let property = try Self.scalar(data.subdata(in: offset..<(offset + 2)), widths: [2])
      events[property] = try Self.scalar(data.subdata(in: (offset + 2)..<(offset + 6)))
    }
    if mode != .xApp, let count = events[0xd222] {
      guard count <= WirelessPTPTransport.maximumObjectsPerStorage else {
        throw WirelessFailure.malformedData
      }
      legacyObjectCount = count
    }
    return events
  }

  /// D227 changes the reported length, independently of the camera's resize preference.
  func withAccurateLegacyLengths<Value: Sendable>(
    _ operation: () async throws -> Value
  ) async throws -> Value {
    guard mode != .xApp else { return try await operation() }
    try await readEvents()
    let value: Value
    do {
      try await setProperty(0xd227, 1, width: 2) { legacyAccurateLengthsEnabled = true }
      value = try await operation()
    } catch {
      // An interrupted wire transaction can already have retired the transport.
      if legacyAccurateLengthsEnabled {
        let cleanup = Task { try await resetLegacyLengthReporting() }
        _ = try? await cleanup.value
      }
      throw error
    }
    // Restore even when cancellation arrives just after the final successful transaction.
    let cleanup = Task { try await resetLegacyLengthReporting() }
    try await cleanup.value
    return value
  }

  func resetLegacyLengthReporting(whileClosing: Bool = false) async throws {
    try await readEvents(whileClosing: whileClosing)
    try await setProperty(0xd227, 0, width: 2, whileClosing: whileClosing) {
      legacyAccurateLengthsEnabled = false
    }
  }
}
