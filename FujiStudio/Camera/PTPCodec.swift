import Foundation

/// Standard PTP USB command/response containers: 12-byte header, at most five UInt32 parameters.
/// ICCameraDevice owns the data phase; its inbound/outbound data arguments are separate payloads.
enum PTPCodec {
    static let maximumDataBytes = 128 * 1024 * 1024

    static func encode(_ command: PTPCommand) throws -> Data {
        guard command.parameters.count <= 5 else { throw PTPError.invalidParameters }
        guard (0x1000...0x1fff).contains(command.opcode) || (0x9000...0x9fff).contains(command.opcode) else {
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

    static func decode(response: Data, data: Data, for command: PTPCommand,
                       maximumDataBytes: Int = maximumDataBytes) throws -> PTPReply {
        guard data.count <= maximumDataBytes else { throw PTPError.payloadTooLarge }
        guard response.count <= 32 else { throw PTPError.oversizedContainer }
        guard response.count >= 12 else { throw PTPError.truncatedContainer }
        // Normalize indices: Data slices need not start at zero. No unaligned integer loads.
        let bytes = [UInt8](response)
        let length = uint32(bytes, 0)
        guard length == response.count, (response.count - 12) % 4 == 0 else { throw PTPError.invalidContainerLength }
        let kind = uint16(bytes, 4)
        guard kind == 3 else { throw PTPError.unexpectedContainerType(kind) }
        let transaction = uint32(bytes, 8)
        guard transaction == command.transactionID else {
            throw PTPError.wrongTransaction(expected: command.transactionID, actual: transaction)
        }
        let code = uint16(bytes, 6)
        guard code == 0x2001 else { throw PTPError.responseCode(code) }
        let parameters = stride(from: 12, to: bytes.count, by: 4).map { uint32(bytes, $0) }
        return PTPReply(opcode: command.opcode, parameters: parameters, transactionID: transaction, responseCode: code, data: data)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
