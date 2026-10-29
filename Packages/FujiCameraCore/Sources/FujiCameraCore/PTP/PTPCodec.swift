import Foundation

/// Standard PTP USB command/response containers: 12-byte header, at most five UInt32 parameters.
/// ICCameraDevice owns the data phase; its inbound/outbound data arguments are separate payloads.
public enum PTPCodec {
  public static let maximumDataBytes = 128 * 1024 * 1024

  public static func encode(_ command: PTPCommand) throws -> Data {
    guard command.parameters.count <= 5 else { throw PTPError.invalidParameters }
    guard (0x1000...0x1fff).contains(command.opcode) || (0x9000...0x9fff).contains(command.opcode)
    else {
      throw PTPError.invalidOpcode(command.opcode)
    }
    var result = Data()
    append(UInt32(12 + 4 * command.parameters.count), to: &result)
    append(UInt16(1), to: &result)
    append(command.opcode, to: &result)
    append(command.transactionID, to: &result)
    for parameter in command.parameters { append(parameter, to: &result) }
    return result
  }

  /// The native callback echoes the submitted logical command. Every field, including its
  /// logical ID, must match before trusting framework-managed response association.
  public static func validateCallbackCommand(_ buffer: Data, for submitted: PTPCommand) throws
    -> PTPCommand
  {
    let callback = try decodeCommand(buffer)
    try validateLogicalEcho(callback, for: submitted)
    return callback
  }

  private static func validateLogicalEcho(_ callback: PTPCommand, for submitted: PTPCommand) throws
  {
    guard callback.opcode == submitted.opcode, callback.parameters == submitted.parameters else {
      throw PTPError.callbackCommandMismatch
    }
    guard callback.transactionID == submitted.transactionID else {
      throw PTPError.wrongTransaction(
        expected: submitted.transactionID, actual: callback.transactionID)
    }
  }

  public static func decodeCommand(_ buffer: Data) throws -> PTPCommand {
    guard buffer.count <= 32 else { throw PTPError.oversizedContainer }
    guard buffer.count >= 12 else { throw PTPError.truncatedContainer }
    let bytes = [UInt8](buffer)
    guard uint32(bytes, 0) == buffer.count, (buffer.count - 12) % 4 == 0 else {
      throw PTPError.invalidContainerLength
    }
    let kind = uint16(bytes, 4)
    guard kind == 1 else { throw PTPError.unexpectedContainerType(kind) }
    let command = PTPCommand(
      opcode: uint16(bytes, 6),
      parameters: stride(from: 12, to: bytes.count, by: 4).map { uint32(bytes, $0) },
      transactionID: uint32(bytes, 8))
    _ = try encode(command)  // Same opcode/parameter restrictions as submitted commands.
    return command
  }

  /// Direct/raw transports must independently match the expected on-wire transaction.
  public static func decode(
    response: Data, data: Data, for command: PTPCommand,
    maximumDataBytes: Int = maximumDataBytes
  ) throws -> PTPReply {
    let container = try responseContainer(response, data: data, maximumDataBytes: maximumDataBytes)
    guard container.transactionID == command.transactionID else {
      throw PTPError.wrongTransaction(
        expected: command.transactionID, actual: container.transactionID)
    }
    return try reply(
      container, raw: response, data: data, command: command, correlation: .directWireTransaction)
  }

  /// Only for the context/run-associated ImageCaptureCore callback. Its command is the original
  /// logical echo; the framework-owned assigned wire ID is observable only in the raw response.
  /// No alleged expected wire ID is synthesized from that observation.
  public static func decodeFrameworkManaged(
    response: Data, data: Data, for submitted: PTPCommand,
    echoedCommand: PTPCommand, maximumDataBytes: Int = maximumDataBytes
  ) throws -> PTPReply {
    try validateLogicalEcho(echoedCommand, for: submitted)
    let container = try responseContainer(response, data: data, maximumDataBytes: maximumDataBytes)
    return try reply(
      container, raw: response, data: data, command: submitted,
      correlation: .imageCaptureCoreCallback(echoedCommand: echoedCommand))
  }

  private struct ResponseContainer {
    let transactionID: UInt32
    let code: UInt16
    let parameters: [UInt32]
  }
  private static func responseContainer(_ response: Data, data: Data, maximumDataBytes: Int) throws
    -> ResponseContainer
  {
    guard data.count <= maximumDataBytes else { throw PTPError.payloadTooLarge }
    guard response.count <= 32 else { throw PTPError.oversizedContainer }
    guard response.count >= 12 else { throw PTPError.truncatedContainer }
    // Normalize slice indices; never use unaligned integer loads.
    let bytes = [UInt8](response)
    guard uint32(bytes, 0) == response.count, (response.count - 12) % 4 == 0 else {
      throw PTPError.invalidContainerLength
    }
    let kind = uint16(bytes, 4)
    guard kind == 3 else { throw PTPError.unexpectedContainerType(kind) }
    return ResponseContainer(
      transactionID: uint32(bytes, 8), code: uint16(bytes, 6),
      parameters: stride(from: 12, to: bytes.count, by: 4).map { uint32(bytes, $0) })
  }
  private static func reply(
    _ container: ResponseContainer, raw: Data, data: Data,
    command: PTPCommand, correlation: PTPCorrelation
  ) throws -> PTPReply {
    guard container.code == 0x2001 else { throw PTPError.responseCode(container.code) }
    return PTPReply(
      opcode: command.opcode, parameters: container.parameters,
      logicalTransactionID: command.transactionID, wireTransactionID: container.transactionID,
      correlation: correlation, responseCode: container.code, rawResponse: raw, data: data)
  }

  private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var little = value.littleEndian
    withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
  }
  private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
  }
  private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
      | UInt32(bytes[offset + 3]) << 24
  }
}
