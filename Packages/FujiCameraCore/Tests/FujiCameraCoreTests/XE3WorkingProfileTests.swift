import Foundation
import Testing
@testable import FujiCameraCore

struct XE3WorkingProfileTests {
    @Test(arguments:["baseline-601","baseline-dr400-daylight","baseline-dr400-weak"])
    func profilePatchesOnlyDeclaredWords(_ name:String) throws {
        let baseline=try xe3Baseline(name),settings=xe3Settings()
        let patch=try XE3WorkingProfile.make(baseline:baseline,settings:settings,source:xe3Metadata())
        #expect(patch.bytes.count == 601)
        #expect(patch.bytes.subdata(in:561..<565) == Data([0xfc,0xff,0xff,0xff]))
        #expect(patch.bytes.subdata(in:573..<577) == Data([0xf6,0xff,0xff,0xff]))
        #expect(patch.bytes.subdata(in:589..<593) == Data([0,0x80,0,0]))
        let allowed=Set([533,541,545,553,557,561,565,569,573,577,581,585,589].flatMap { Array($0..<$0+4) })
        #expect((0..<601).filter { !allowed.contains($0) }.allSatisfy { patch.bytes[$0] == baseline[$0] })
        #expect(patch.bytes[533] == 0x90 && patch.bytes[534] == 1) // requested DR400 on DR200 capture
        #expect(patch.expectedLensOptimizer)
    }
    @Test func noiseReductionLookupCoversNineLevels() throws {
        for (level,word) in [(-4,0x8000),(-3,0x7000),(-2,0x4000),(-1,0x3000),(0,0x2000),(1,0x1000),(2,0),(3,0x6000),(4,0x5000)] {
            var settings=xe3Settings();settings.noiseReduction=level
            let bytes=try XE3WorkingProfile.make(baseline:xe3Baseline(),settings:settings,source:xe3Metadata()).bytes
            #expect(bytes.subdata(in:589..<593) == Data([UInt8(truncatingIfNeeded:word),UInt8(word >> 8),0,0]))
        }
    }
    @Test func allFifteenFilmsHaveIndependentNativeCodes() throws {
        for (film,code):(FilmSimulation,UInt8) in [(.provia,1),(.velvia,2),(.astia,3),(.proNegHi,4),(.proNegStd,5),(.monochrome,6),(.monochromeYellow,7),(.monochromeRed,8),(.monochromeGreen,9),(.sepia,10),(.classicChrome,11),(.acros,12),(.acrosYellow,13),(.acrosRed,14),(.acrosGreen,15)] {
            var settings=xe3Settings();settings.film=film
            #expect(try XE3WorkingProfile.make(baseline:xe3Baseline(),settings:settings,source:xe3Metadata()).bytes[541] == code)
        }
    }
    @Test func kelvin5310IsRejectedAndNativePresetsAreAccepted() throws {
        var settings=xe3Settings();settings.kelvin=5310
        #expect(throws:CameraServiceError.unsupportedSettings) { try XE3WorkingProfile.make(baseline:xe3Baseline(),settings:settings,source:xe3Metadata()) }
        for kelvin in [5000,6300,7100] { settings.kelvin=kelvin;_ = try XE3WorkingProfile.make(baseline:xe3Baseline(),settings:settings,source:xe3Metadata()) }
    }
    @Test func unsupportedEffectsAndForeignFramesNeverBecomeSilentOff() throws {
        var settings=xe3Settings();settings.colorChrome = .off
        #expect(throws:CameraServiceError.unsupportedSettings) { try XE3WorkingProfile.make(baseline:xe3Baseline(),settings:settings,source:xe3Metadata()) }
        #expect(throws:CameraServiceError.unsupportedProfile) { try XE3WorkingProfile.make(baseline:ProductionProfileFixture().baseline,settings:xe3Settings(),source:xe3Metadata()) }
    }
}
func xe3Baseline(_ name:String="baseline-601") throws -> Data {
    let url=try #require(Bundle.module.url(forResource:name,withExtension:"bin",subdirectory:"Fixtures/XE3/1.30"))
    return try Data(contentsOf:url)
}
func xe3Metadata(orientation:Int=1) -> RAWMetadata {
    .init(cameraModel:"X-E3",containerGeometry:.init(width:6048,height:4038),recordedGeometry:.init(width:6000,height:4000),recordedAspect:.init(width:3,height:2),cropTop:21,cropLeft:16,orientation:orientation,compression:.lossless,bitDepth:14,rafVersion:"0130")
}
func xe3Settings() -> RecipeSettings {
    .init(film:.classicChrome,grain:.init(strength:.off,size:nil),dynamicRange:400,whiteBalance:.temperature,whiteBalanceRed:-4,whiteBalanceBlue:-2,kelvin:6300,highlightTenths:-10,shadowTenths:20,colorTenths:-20,sharpnessTenths:0,noiseReduction:-4)
}

extension XE3WorkingProfileTests {
    @Test func nativeRecipeFreezesWBAndPreservesUnknownFieldsOnEdit() throws {
        let fields:[UInt16:Data] = [1:Data([13]),2:Data([3]),3:Data([2]),4:Data([8]),5:Data([13]),6:Data([11]),7:Data([6]),8:Data([5]),9:Data([2]),10:Data([7]),11:Data([4]),12:Data([0]),13:Data([0xb9,1])]
        let context=RecipeCameraContext(model:"X-E3",firmware:"1.30",capability:"xe3-1.30-FF129505-v1",sessionIdentity:UUID(),sessionGeneration:1)
        let original=try XE3RecipeCodec.recipe(slot:1,nameData:Data("Synthetic\0".utf8),properties:fields,context:context,importedAt:Date(timeIntervalSince1970:1000))
        let codecs=RecipeCodecRegistry(),settings=try codecs.requireSettings(original)
        #expect(settings.whiteBalanceRed == -4 && settings.whiteBalanceBlue == -2)
        #expect(settings.kelvin == 6300 && settings.film == .classicChrome)
        var unknown=fields;unknown[0xff01]=Data([0xab,0xcd])
        let opaque=try XE3RecipeCodec.recipe(slot:1,nameData:original.importedName,properties:unknown,context:context,importedAt:original.importedAt)
        var edit=try codecs.editableSettings(opaque);edit.film = .provia
        let result=try codecs.encodeEditedRecipe(edit,preserving:opaque)
        #expect(result.importedSettings.first { $0.code == 0xff01 }?.raw == Data([0xab,0xcd]))
        #expect(!codecs.assess(result).issues.isEmpty)
        #expect(result.settingsDigest != opaque.settingsDigest)
    }
}
