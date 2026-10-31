@testable import FujiCameraCore
import Foundation
import Testing

struct XT5WorkingProfileTests {
    @Test func snapshotSupportReassessesFrozenRawValuesInsteadOfTrustingOldIssues() throws {
        let f=try ProductionProfileFixture()
        #expect(!f.bank.renderingIssues.isEmpty)
        #expect(try f.bank.settings(using: RecipeCodecRegistry()).grain == GrainSettings(strength: .strong, size: .small))
        try f.bank.requireRenderable(using: RecipeCodecRegistry())
        var changed=f.properties;changed[0xD1A4]=2
        let unsupported=try f.bank(changed)
        #expect(throws:RecipeImportError.self) { try unsupported.requireRenderable(using: RecipeCodecRegistry()) }
    }
    @Test func freshMeasuredFrameAndFrozenSnapshotProduceBoundedRequestedPatch() throws {
        let f=try ProductionProfileFixture()
        let normalized=try XT5WorkingProfile.normalize(f.bank)
        #expect(normalized.grain == GrainSettings(strength: .strong, size: .small))
        #expect(normalized.noiseReduction == -4)
        #expect(normalized.lensOptimizerRequested == true)
        let patch=try XT5WorkingProfile.make(baseline:f.baseline,recipe:f.bank,metadata:f.metadata)
        #expect(patch.bytes.count == 625)
        #expect(patch.bytes[593] == 1)
        #expect(patch.bytes.subdata(in:561..<565) == Data([0xfc,0xff,0xff,0xff]))
        let allowed=Set([533,541,545,549,553,557,561,565,569,573,577,581,585,589,593,609,617].flatMap { Array($0..<$0+4) })
        #expect((0..<625).filter { !allowed.contains($0) }.allSatisfy { patch.bytes[$0] == f.baseline[$0] })
        #expect(f.bank.id == patch.recipeID && f.bank.settingsDigest == patch.settingsDigest)
        #expect(patch.settings.grain == GrainSettings(strength: .strong, size: .small))
    }
    @Test func differentStartingSettingsAreFullyReplacedByTheFrozenRecipe() throws {
        let f = try ProductionProfileFixture()
        // Independent expected words for this fixture's frozen recipe, including fixed output policy.
        let expected: [Int: Int32] = [
            533: 400, 541: 11, 545: 3, 549: 3, 553: 2, 557: 2, 561: -4,
            565: 3, 569: 6700, 573: -20, 577: 20, 581: 0, 585: 0,
            589: 32768, 593: 1, 609: 2, 617: 0,
        ]
        func word(_ value: Int32) -> Data {
            Data((0..<4).map { UInt8(truncatingIfNeeded: UInt32(bitPattern: value) >> ($0 * 8)) })
        }
        var observed = f.baseline
        // The four writable differences captured by the phone journal.
        for (offset, value): (Int, Int32) in [(541, 11), (573, -20), (577, -20), (581, 40)] {
            observed.replaceSubrange(offset..<offset + 4, with: word(value))
        }
        var baselines = [observed]
        for value in [Int32.min, -1, 0, 1, Int32.max] {
            var changed = f.baseline
            for offset in expected.keys {
                changed.replaceSubrange(offset..<offset + 4, with: word(value))
            }
            baselines.append(changed)
        }
        let writable = Set(expected.keys.flatMap { Array($0..<$0 + 4) })
        for baseline in baselines {
            let patch = try XT5WorkingProfile.make(baseline: baseline, recipe: f.bank, metadata: f.metadata)
            for (offset, value) in expected {
                #expect(patch.bytes.subdata(in: offset..<offset + 4) == word(value))
            }
            #expect((0..<625).filter { !writable.contains($0) }.allSatisfy { patch.bytes[$0] == baseline[$0] })
            #expect(patch.baselineSHA256 == ResourceChecksum.sha256(baseline))
            #expect(patch.recipeID == f.bank.id && patch.settingsDigest == f.bank.settingsDigest)
        }
    }
    @Test func everyChangedStructuralByteAndUnobservedSourceGeometryRefuse() throws {
        let f=try ProductionProfileFixture()
        let writable = Set([533,541,545,549,553,557,561,565,569,573,577,581,585,589,593,609,617].flatMap { Array($0..<$0+4) })
        for index in (0..<625).filter({ !writable.contains($0) }) {
            var changed=f.baseline;changed[index] ^= 1
            #expect(throws: CameraServiceError.unsupportedProfile) { try XT5WorkingProfile.make(baseline:changed,recipe:f.bank,metadata:f.metadata) }
        }
        for data in [Data(f.baseline.dropLast()),f.baseline+Data([0])] {
            #expect(throws: CameraServiceError.unsupportedProfile) { try XT5WorkingProfile.make(baseline:data,recipe:f.bank,metadata:f.metadata) }
        }
        let square=RAWMetadata(cameraModel:"X-T5",containerGeometry:.init(width:7872,height:5196),recordedGeometry:.init(width:5000,height:5000),recordedAspect:.init(width:1,height:1),cropTop:0,cropLeft:0,orientation:8)
        #expect(throws: CameraServiceError.unsupportedSource) { try XT5WorkingProfile.make(baseline:f.baseline,recipe:f.bank,metadata:square) }
    }
    @Test func opaqueTupleAndFiniteDomainsAreEnforcedWithoutDroppingDormantRequests() throws {
        let f=try ProductionProfileFixture()
        for (code,value):(UInt16,UInt16) in [(0xD18E,8),(0xD18F,3),(0xD1A3,0),(0xD1A4,2),(0xD195,4),(0xD198,2),(0xD192,99),(0xD191,1)] {
            var p=f.properties;p[code]=value
            #expect(throws: CameraServiceError.unsupportedSettings) { try XT5WorkingProfile.normalize(f.bank(p)) }
        }
        for (raw,size):(UInt16,GrainSettings) in [(6,.init(strength:.off,size:.small)),(7,.init(strength:.off,size:.large))] {
            var p=f.properties;p[0xD195]=raw
            let bank=try f.bank(p),patch=try XT5WorkingProfile.make(baseline:f.baseline,recipe:bank,metadata:f.metadata)
            #expect(patch.settings.grain == size && patch.bytes[545] == 1)
            let report=patch.effective(lensOptimizer:false)
            #expect(report.dormantGrainSizeNotSerialized)
            #expect(report.lensOptimizerRequested && !report.lensOptimizerEffective && report.lensOptimizerAdjusted)
            #expect(bank.importedSettings.first { $0.code == 0xD195 }?.raw == ProtocolProbeFixtures.word(raw))
        }
    }
}

struct ProductionProfileFixture {
    let baseline:Data,properties:[UInt16:UInt16],bank:RecipeSnapshot
    let metadata=RAWMetadata(cameraModel:"X-T5",containerGeometry:.init(width:7872,height:5196),recordedGeometry:.init(width:7728,height:5152),recordedAspect:.init(width:3,height:2),cropTop:21,cropLeft:12,orientation:8,captureDynamicRange:400)
    init() throws {
        var b=Data([29,0,8]);for c in "FF179502".utf16 { b.append(contentsOf:[UInt8(c),0]) };b.append(Data(repeating:0,count:513-b.count))
        let values:[Int32]=[2,7,7,2,0,400,0,15,1,3,1,0,3,-4,0,20,20,0,0,32768,2,1,0,1,3,0,0,2]
        for v in values { b.append(contentsOf:(0..<4).map { UInt8(truncatingIfNeeded:UInt32(bitPattern:v) >> ($0*8)) }) };baseline=b
        let f=try BatchFixture();var p=f.properties;p[0xD18E]=7;p[0xD18F]=2;p[0xD1A3]=1;p[0xD1A4]=1;p[0xD195]=3;properties=p
        bank=try f.bank(slot:7,properties:p)
    }
    func bank(_ properties:[UInt16:UInt16]) throws -> RecipeSnapshot { try BatchFixture().bank(slot:7,properties:properties) }
}
