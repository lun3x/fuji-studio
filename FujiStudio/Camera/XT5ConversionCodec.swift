import Foundation

/// Standard ObjectInfo field order used by pinned libfuji's vendor 900C RAF upload. No profile
/// offsets, conversion triggers, response-handle ownership assumptions or deletion logic.
enum XT5ConversionCodec {
    static func uploadInfo(byteCount: Int) throws -> Data {
        guard byteCount > 0, byteCount <= PTPCodec.maximumDataBytes, let count = UInt32(exactly: byteCount) else { throw PTPError.payloadTooLarge }
        var bytes = Data(repeating: 0, count: 52)
        bytes[4] = 0x02; bytes[5] = 0xf8 // Vendor RAF transfer, not backup format 5000.
        for index in 0..<4 { bytes[8 + index] = UInt8(truncatingIfNeeded: count >> (8 * index)) }
        let name = "FUP_FILE.dat"
        bytes.append(UInt8(name.utf16.count + 1))
        for unit in name.utf16 { bytes.append(contentsOf: [UInt8(truncatingIfNeeded: unit), UInt8(unit >> 8)]) }
        bytes.append(contentsOf: [0,0,0,0,0]) // String terminator and three empty PTP strings.
        return bytes
    }
    static func objectHandles(_ data: Data) throws -> [UInt32] {
        guard data.count >= 4 else { throw XT5ProtocolError.truncated }
        let bytes = Data(data)
        func word(_ offset: Int) -> UInt32 {
            bytes[offset..<(offset + 4)].enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) }
        }
        let count = Int(word(0))
        guard count <= 4096 else { throw XT5ProtocolError.oversized }
        guard data.count >= 4 + count * 4 else { throw XT5ProtocolError.truncated }
        guard data.count == 4 + count * 4 else { throw XT5ProtocolError.trailingBytes }
        var result: [UInt32] = []
        for offset in stride(from: 4, to: data.count, by: 4) { result.append(word(offset)) }
        guard Set(result).count == result.count, !result.contains(0), !result.contains(UInt32.max) else { throw PTPError.invalidParameters }
        return result
    }
}
