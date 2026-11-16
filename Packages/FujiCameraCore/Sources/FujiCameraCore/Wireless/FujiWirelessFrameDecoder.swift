import Foundation

/// Fuji starts the command socket with a PTP/IP-style exchange, then switches to USB-style
/// containers over TCP. Structures are source-observed in pinned libfuji and camlib.
public struct FujiWirelessFrameDecoder {
  static let maximumReadBytes = 65_536
  static let headerBytes = 12
  static let initHeaderBytes = 8
  static let maximumInitBytes = 82
  private static let initNameOffset = 28
  private static let version: UInt32 = 0x8f53_e4f2

  struct Header {
    let length: Int
    let type: UInt16
    let code: UInt16
    let transaction: UInt32

    var payloadLength: Int { length - FujiWirelessFrameDecoder.headerBytes }
  }

  private var buffer = Data()
  private var retainedReadBytes = 0

  var availableBytes: Int { buffer.count }

  mutating func supply(_ chunk: Data) throws {
    precondition(buffer.isEmpty)
    guard chunk.count <= Self.maximumReadBytes else { throw PTPError.oversizedContainer }
    buffer = chunk
    retainedReadBytes = chunk.count
  }

  /// Reports bytes held during extraction, including the payload copy for a split read.
  mutating func take(_ count: Int) -> (bytes: Data, heldBytes: Int) {
    precondition(count <= buffer.count)
    let originalBytes = retainedReadBytes
    if count == buffer.count {
      let bytes = buffer
      buffer = Data()
      retainedReadBytes = 0
      return (bytes, originalBytes)
    }
    let end = buffer.startIndex + count
    let bytes = buffer.subdata(in: buffer.startIndex..<end)
    buffer = buffer[end...]
    // The remainder may share the read's storage, including bytes already consumed.
    return (bytes, originalBytes + count)
  }

  /// The caller supplies the client GUID for the selected protocol/peer.
  public static func initializationRequest(clientName: String, clientGUID: Data) throws -> Data {
    let name = Array(clientName.utf16.prefix(27))
    guard clientGUID.count == 16, !name.isEmpty, name.count <= 26, !name.contains(0) else {
      throw PTPError.invalidParameters
    }
    var request = Data()
    append(UInt32(maximumInitBytes), to: &request)
    append(UInt32(1), to: &request)
    append(version, to: &request)
    request.append(clientGUID)
    for unit in name { append(unit, to: &request) }
    request.append(Data(repeating: 0, count: maximumInitBytes - request.count))
    return request
  }

  public static func xAppClientGUID(localIPv4Bytes: Data?) throws -> Data {
    guard let address = localIPv4Bytes, address.count == 4 else { throw WirelessFailure.routeUnavailable }
    // The XApp prefix is followed by the connected local IPv4 in little-endian order.
    let prefix: [UInt8] = [0xad, 0xa5, 0x48, 0x5d, 0x87, 0xb2, 0x7f, 0x0b, 0xd3, 0xd5, 0xde, 0xd0]
    return Data(prefix + address.reversed())
  }

  static func validateInitializationRequest(_ request: Data) throws {
    guard request.count == maximumInitBytes, uint32(request, 0) == maximumInitBytes,
      uint32(request, 4) == 1, uint32(request, 8) == version
    else { throw PTPError.invalidParameters }
    _ = try initializationName(request)
  }

  static func initializationLength(_ prefix: Data) throws -> Int {
    let length = Int(uint32(prefix, 0))
    guard length <= maximumInitBytes else { throw PTPError.oversizedContainer }
    switch uint32(prefix, 4) {
    case 2 where length >= initNameOffset + 2 && length.isMultiple(of: 2):
      return length
    case 5 where length == 12:  // PTP/IP InitFail, with a UInt32 failure reason.
      return length
    default:
      throw PTPError.invalidContainerLength
    }
  }

  static func validateInitializationReply(_ reply: Data) throws {
    if uint32(reply, 4) == 5 { throw PTPError.authorizationDenied }
    _ = try initializationName(reply)
  }

  static func length(_ lengthBytes: Data) -> Int { Int(uint32(lengthBytes, 0)) }

  static func header(_ bytes: Data, for command: PTPCommand) throws -> Header {
    let header = Header(
      length: length(bytes), type: uint16(bytes, 4), code: uint16(bytes, 6),
      transaction: uint32(bytes, 8))
    guard header.type == 2 || header.type == 3 else {
      throw PTPError.unexpectedContainerType(header.type)
    }
    guard header.transaction == command.transactionID else {
      throw PTPError.wrongTransaction(expected: command.transactionID, actual: header.transaction)
    }
    if header.type == 2 {
      guard header.code == command.opcode else { throw PTPError.invalidOpcode(header.code) }
    } else {
      guard header.length <= 32 else { throw PTPError.oversizedContainer }
      guard header.payloadLength.isMultiple(of: 4) else { throw PTPError.invalidContainerLength }
      guard (0x2000...0x2fff).contains(header.code) || (0xa000...0xafff).contains(header.code)
      else { throw PTPError.responseCode(header.code) }
    }
    return header
  }

  static func dataHeader(length: Int, command: PTPCommand) -> Data {
    var header = Data()
    append(UInt32(headerBytes + length), to: &header)
    append(UInt16(2), to: &header)
    append(command.opcode, to: &header)
    append(command.transactionID, to: &header)
    return header
  }

  static func initializationName(_ packet: Data) throws -> String {
    let units = stride(from: initNameOffset, to: packet.count, by: 2).map { uint16(packet, $0) }
    guard let end = units.firstIndex(of: 0), units[end...].allSatisfy({ $0 == 0 }),
      String(decoding: units[..<end], as: UTF16.self).utf16.elementsEqual(units[..<end])
    else { throw PTPError.sessionFailure("Invalid Fuji initialization name") }
    return String(decoding: units[..<end], as: UTF16.self)
  }

  private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
  }

  private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
    let start = data.startIndex + offset
    return UInt16(data[start]) | UInt16(data[start + 1]) << 8
  }

  static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
    UInt32(uint16(data, offset)) | UInt32(uint16(data, offset + 2)) << 16
  }
}
