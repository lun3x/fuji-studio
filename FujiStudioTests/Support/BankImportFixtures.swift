import Foundation

/// Synthetic slot data exercising the documented wire shapes. Not an observed seven-bank capture.
enum BankImportFixtures {
    static var properties: [UInt16: Data] {
        var values = Dictionary(uniqueKeysWithValues: (UInt16(0xD18E)...0xD1A4).map { ($0, Data([0,0])) })
        values[0xD18E] = Data([7,0]); values[0xD18F] = Data([4,0])
        values[0xD190] = Data([100,0]); values[0xD192] = Data([11,0]); values[0xD195] = Data([7,0])
        values[0xD196] = Data([1,0]); values[0xD197] = Data([1,0]); values[0xD198] = Data([1,0])
        values[0xD199] = Data([2,0]); values[0xD19C] = Data([0xe0,0x15]); values[0xD1A1] = Data([0,0x20])
        values[0xD1A3] = Data([1,0]); values[0xD1A4] = Data([1,0])
        return values
    }
}
