import Foundation

/// Hand-authored standard PTP grammar, never an observed X-T5 capture.
enum ProtocolProbeFixtures {
    static func word(_ value: UInt16) -> Data { Data([UInt8(truncatingIfNeeded: value), UInt8(value >> 8)]) }
    static func string(_ text: String) -> Data {
        var result = Data([UInt8(text.utf16.count + 1)])
        for unit in text.utf16 { result.append(word(unit)) }
        result.append(contentsOf: [0, 0]); return result
    }
    static func array(_ values: [UInt16]) -> Data {
        var result = Data([UInt8(values.count), 0, 0, 0])
        values.forEach { result.append(word($0)) }; return result
    }
    static func deviceInfo(model: String = "X-T5", properties: [UInt16] = [0xD16E, 0xD185, 0xD18C, 0xD18D]) -> Data {
        var result = Data([100, 0, 14, 0, 0, 0, 100, 0, 0, 0, 0])
        result.append(array([0x1001, 0x1014, 0x1015]))
        result.append(array([])); result.append(array(properties))
        result.append(array([])); result.append(array([0x3801]))
        ["FUJIFILM", model, "4.20", "PRIVATE-SERIAL"].forEach { result.append(string($0)) }
        return result
    }
    static let modeDescriptor = Data([0x6e, 0xd1, 4, 0, 0, 5, 0, 6, 0, 2, 3, 0, 5, 0, 6, 0, 8, 0])
    static let selectorDescriptor = Data([0x8c, 0xd1, 4, 0, 1, 1, 0, 3, 0, 1, 1, 0, 7, 0, 1, 0])
}
