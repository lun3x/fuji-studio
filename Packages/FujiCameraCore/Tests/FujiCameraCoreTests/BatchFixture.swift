import Foundation
@testable import FujiCameraCore
struct BatchFixture {
    let baseline: Data
    let properties: [UInt16:UInt16]
    let banks: [RecipeSnapshot]
    init() throws {
        var b = Data(repeating: 0xa5, count: 625); b.replaceSubrange(0..<3,with: [29,0,8])
        let words: [Int:UInt32] = [5:400,7:15,8:1,9:3,10:1,11:0,12:3,13:UInt32(bitPattern: -4),14:0,15:20,16:20,17:0,18:0,19:32768,20:2,21:1,22:0,24:3,25:0,26:0,6:0]
        for (i,v) in words { b.replaceSubrange(513+i*4..<517+i*4,with: (0..<4).map { UInt8(truncatingIfNeeded: v >> ($0*8)) }) }
        baseline = b
        var p = Dictionary(uniqueKeysWithValues: (UInt16(0xD18E)...0xD1A4).map { ($0,UInt16(1)) })
        for (k,v): (UInt16,UInt16) in [0xD190:400,0xD191:0,0xD192:11,0xD193:0,0xD194:0,0xD195:7,0xD196:3,0xD197:2,0xD198:1,0xD199:2,0xD19A:65532,0xD19B:3,0xD19C:6700,0xD19D:65516,0xD19E:20,0xD19F:0,0xD1A0:0,0xD1A1:32768,0xD1A2:0] { p[k] = v }
        properties = p
        banks = try (1...7).map { slot in var values = p; if slot == 7 { values[0xD195] = 3 }; return try Self.makeBank(slot: slot, properties: values) }
    }
    func bank(slot: Int, properties: [UInt16:UInt16]) throws -> RecipeSnapshot { try Self.makeBank(slot: slot, properties: properties) }
    private static func makeBank(slot: Int, properties: [UInt16:UInt16]) throws -> RecipeSnapshot {
        try XT5RecipeCodec.recipe(slot: slot, nameData: ProtocolProbeFixtures.string("Synthetic \(slot)"), properties: properties.mapValues { ProtocolProbeFixtures.word($0) }, context: .init(model: "X-T5",firmware: "4.31",capability: "X-T5_0200",sessionIdentity: UUID(),sessionGeneration: 1), importedAt: Date())
    }
}