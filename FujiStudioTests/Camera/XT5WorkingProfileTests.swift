@testable import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

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
    @Test func everyChangedFrameByteAndUnobservedSourceGeometryRefuse() throws {
        let f=try ProductionProfileFixture()
        for index in 0..<625 {
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
        for (code,value):(UInt16,UInt16) in [(0xD18E,8),(0xD18F,3),(0xD1A3,0),(0xD1A4,2),(0xD195,4),(0xD198,2),(0xD192,99),(0xD191,1),(0xD193,1),(0xD194,1)] {
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
    let metadata=RAWMetadata(cameraModel:"X-T5",containerGeometry:.init(width:7872,height:5196),recordedGeometry:.init(width:7728,height:5152),recordedAspect:.init(width:3,height:2),cropTop:21,cropLeft:12,orientation:8)
    init() throws {
        var b=Data([29,0,8]);for c in "FF179502".utf16 { b.append(contentsOf:[UInt8(c),0]) };b.append(Data(repeating:0,count:513-b.count))
        let values:[Int32]=[2,7,7,2,0,400,0,15,1,3,1,0,3,-4,0,20,20,0,0,32768,2,1,0,1,3,0,0,2]
        for v in values { b.append(contentsOf:(0..<4).map { UInt8(truncatingIfNeeded:UInt32(bitPattern:v) >> ($0*8)) }) };baseline=b
        let f=try BatchFixture();var p=f.properties;p[0xD18E]=7;p[0xD18F]=2;p[0xD1A3]=1;p[0xD1A4]=1;p[0xD195]=3;properties=p
        bank=try f.bank(slot:7,properties:p)
    }
    func bank(_ properties:[UInt16:UInt16]) throws -> RecipeSnapshot { try BatchFixture().bank(slot:7,properties:properties) }
}
