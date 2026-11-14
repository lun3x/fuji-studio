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
    guard phoneObjectCount != nil else { throw WirelessFailure.unavailableStorage }
    selectedStorage = 0  // The legacy single-card gallery has no slot selection command.
    return [0]
  }

  @discardableResult
  func readEvents(whileClosing: Bool = false) async throws -> [UInt32: UInt32] {
    let data = try await execute(0x1015, [0xd212], whileClosing: whileClosing).data
    guard data.count >= 2 else { throw WirelessFailure.malformedData }
    let count = Int(try Self.scalar(Data(data.prefix(2)), widths: [2]))
    guard data.count == 2 + count * 6, count <= 4096 else { throw WirelessFailure.malformedData }
    var events: [UInt32: UInt32] = [:]
    for offset in stride(from: 2, to: data.count, by: 6) {
      let property = try Self.scalar(data.subdata(in: offset..<(offset + 2)), widths: [2])
      events[property] = try Self.scalar(data.subdata(in: (offset + 2)..<(offset + 6)))
    }
    if mode == .phone, let count = events[0xd222] {
      guard count <= WirelessPTPTransport.maximumObjectsPerStorage else {
        throw WirelessFailure.malformedData
      }
      phoneObjectCount = count
    }
    return events
  }

  func resetPhoneOriginalSize(whileClosing: Bool = false) async throws {
    try await readEvents(whileClosing: whileClosing)
    try await setProperty(0xd227, 0, width: 2, whileClosing: whileClosing)
    phoneOriginalMode = false
  }
}
