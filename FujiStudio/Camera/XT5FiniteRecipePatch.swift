import FujiCameraCore
import Foundation

/// Finite engineering experiment only. Never clears RecipeSnapshot.renderingIssues.
enum XT5RecipeBatchIssue: Error, Sendable {
    case invalidReference, bankMismatch, unsupportedDomain, baselineMismatch, readbackMismatch, cleanupFailed, incompleteBatch
}
struct XT5FiniteRecipePatch: Sendable {
    static let offsets = [533,541,545,549,553,557,561,565,569,573,577,581,585,589,609,617]
    let sourceSHA256: String
    let baseline: Data
    let bytes: Data
    let slot: Int
    let dormantGrainSizeNotApplied: Bool

    static func sameBanks(_ a: [RecipeSnapshot], _ b: [RecipeSnapshot]) -> Bool {
        guard a.map(\.slot).sorted() == Array(1...7), b.map(\.slot).sorted() == Array(1...7) else { return false }
        return a.allSatisfy { bank in b.contains { sameBank(bank,$0) } }
    }
    static func sameBank(_ a: RecipeSnapshot, _ b: RecipeSnapshot) -> Bool {
        a.slot == b.slot && a.importedName == b.importedName && a.importedSettings == b.importedSettings &&
        a.cameraContext.model == b.cameraContext.model && a.cameraContext.firmware == b.cameraContext.firmware && a.cameraContext.capability == b.cameraContext.capability
    }
    static func make(bank: RecipeSnapshot, referenceBanks: [RecipeSnapshot], reference: XT5FilmProbeReference) throws -> Self {
        guard sameBanks(referenceBanks,referenceBanks), referenceBanks.contains(where: { sameBank($0,bank) }),
              reference.baseline.count == 625, reference.baseline.prefix(3) == Data([29,0,8]),
              bank.cameraContext.model == "X-T5", bank.cameraContext.firmware == "4.31", bank.cameraContext.capability == "X-T5_0200" else { throw XT5RecipeBatchIssue.invalidReference }
        // Observed per-source original words, not a general header/count grammar. Opaque words
        // are neither interpreted nor reconstructed. Current baseline must later match ALL bytes.
        let expected: [Int:UInt32] = [5:400,6:0,7:15,8:1,9:3,10:1,11:0,12:3,13:UInt32(bitPattern:-4),14:0,15:20,16:20,17:0,18:0,19:32768,20:2,21:1,22:0,24:3,25:0,26:0]
        for (index,value) in expected {
            let offset = 513 + index*4
            guard reference.baseline.subdata(in: offset..<offset+4) == word(value) else { throw XT5RecipeBatchIssue.baselineMismatch }
        }
        let all = try referenceBanks.map(properties)
        let p = try properties(bank)
        // Finite observed domains come from retained snapshots, never per-slot XML constants.
        // Public documented bounds additionally reject unsupported reference files.
        for code in UInt16(0xD18E)...0xD1A4 {
            guard all.contains(where: { $0[code] == p[code] }) else { throw XT5RecipeBatchIssue.unsupportedDomain }
        }
        for values in all {
            func v(_ code: UInt16) -> UInt16 { values[code]! }
            func s(_ code: UInt16) -> Int { Int(Int16(bitPattern:v(code))) }
            guard [100,400].contains(v(0xD190)), v(0xD191) == 0, [1,11,12,14,15].contains(v(0xD192)),
                  v(0xD193) == 0, v(0xD194) == 0, [3,6,7].contains(v(0xD195)),
                  (1...3).contains(v(0xD196)), (1...3).contains(v(0xD197)), v(0xD198) == 1,
                  [2,32775].contains(v(0xD199)), (-9...9).contains(s(0xD19A)), (-9...9).contains(s(0xD19B)),
                  (2500...10000).contains(v(0xD19C)), [0x8000,0x7000,0x4000,0x3000,0x2000,0x1000,0,0x6000,0x5000].contains(v(0xD1A1)),
                  [UInt16(0xD19D),0xD19E].allSatisfy({ (-20...40).contains(s($0)) && s($0)%5 == 0 }),
                  [UInt16(0xD19F),0xD1A0].allSatisfy({ (-40...40).contains(s($0)) && s($0)%10 == 0 }),
                  (-50...50).contains(s(0xD1A2)), s(0xD1A2)%10 == 0 else { throw XT5RecipeBatchIssue.unsupportedDomain }
        }
        var output = reference.baseline
        let rules: [(Int,UInt16,Bool)] = [(533,0xD190,false),(541,0xD192,false),(549,0xD196,false),(557,0xD199,false),(561,0xD19A,true),(565,0xD19B,true),(569,0xD19C,false),(573,0xD19D,true),(577,0xD19E,true),(581,0xD19F,true),(585,0xD1A0,true),(589,0xD1A1,false),(609,0xD197,false),(617,0xD1A2,true)]
        for (offset,code,signed) in rules {
            let value = p[code]!
            output.replaceSubrange(offset..<offset+4,with: word(signed ? UInt32(bitPattern:Int32(Int16(bitPattern:value))) : UInt32(value)))
        }
        output.replaceSubrange(545..<549,with:word(p[0xD195] == 3 ? 3 : 1))
        output.replaceSubrange(553..<557,with:word(2))
        return Self(sourceSHA256:reference.sourceSHA256,baseline:reference.baseline,bytes:output,slot:bank.slot,dormantGrainSizeNotApplied:p[0xD195] != 3)
    }
    private static func properties(_ bank: RecipeSnapshot) throws -> [UInt16:UInt16] {
        guard bank.importedSettings.count == 23, Set(bank.importedSettings.map(\.code)) == Set(UInt16(0xD18E)...0xD1A4), bank.importedSettings.allSatisfy({ $0.raw.count == 2 }) else { throw XT5RecipeBatchIssue.invalidReference }
        return Dictionary(uniqueKeysWithValues:bank.importedSettings.map { ($0.code, UInt16($0.raw[0]) | UInt16($0.raw[1]) << 8) })
    }
    private static func word(_ value: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded:value >> ($0*8)) }) }
}
