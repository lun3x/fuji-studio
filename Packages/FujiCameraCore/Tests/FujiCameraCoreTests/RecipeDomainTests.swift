import Foundation
import Testing
@testable import FujiCameraCore

struct RecipeDomainTests {
    @Test func semanticAssessmentUsesHumanValuesAndRetainsNativeSnapshot() throws {
        let f = try ProductionProfileFixture()
        let settings = try RecipeCodecRegistry().requireSettings(f.bank)
        #expect(settings.film == .classicChrome)
        #expect(settings.grain == GrainSettings(strength: .strong, size: .small))
        #expect(settings.whiteBalanceRed == -4)
        #expect(settings.noiseReduction == -4)
        #expect(GrainSettings(strength: .weak, size: nil).size == nil)
        #expect(f.bank.settingsDigest == (try RecipeCodecRegistry().encodeEditedRecipe(settings, preserving: f.bank)).settingsDigest)
    }
    @Test func currentPayloadUpgradePreservesFrozenHistory() throws {
        let data = Data(legacyReport.utf8)
        let upgraded = try RecipePayloadUpgrade.convert(data)
        let report = try JSONDecoder().decode(EffectiveRecipeReport.self, from: upgraded)
        #expect(report.requested.film == .classicChrome)
        #expect(report.requested.whiteBalanceRed == -4)
        #expect(report.requested.grain == GrainSettings(strength: .off, size: .large))
        #expect(report.supportVersion == "frozen-support")
        #expect(report.lensOptimizerAdjusted)
        #expect(try RecipePayloadUpgrade.convert(upgraded) == upgraded)
        let object = try #require(JSONSerialization.jsonObject(with: upgraded) as? [String: Any])
        #expect(object["frozenDigest"] as? String == "unchanged-frozen-digest")
        #expect(object["assetID"] as? String == "photos/asset-42")
    }
    @Test func failedUpgradeRejectsUnknownNativeValuesWithoutChangingInput() {
        let bad = Data(legacyReport.replacingOccurrences(of: "\"film\":11", with: "\"film\":99").utf8)
        #expect(throws: (any Error).self) { try RecipePayloadUpgrade.convert(bad) }
        #expect(String(data: bad, encoding: .utf8)?.contains("\"film\":99") == true)
    }
    @Test func offlineEditPreservesUnsupportedNativeBytes() throws {
        let f = try ProductionProfileFixture()
        var properties = f.properties; properties[0xD1A4] = 2
        let original = try f.bank(properties)
        let codecs = RecipeCodecRegistry()
        var edit = try codecs.editableSettings(original)
        edit.film = .provia
        let changed = try codecs.encodeEditedRecipe(edit, preserving: original)
        #expect(changed.importedSettings.first { $0.code == 0xD1A4 }?.raw == Data([2,0]))
        #expect(!codecs.assess(changed).issues.isEmpty)
        #expect(changed.id != original.id)
        #expect(original.importedSettings.first { $0.code == 0xD192 }?.raw == Data([11,0]))
    }
}
let legacyReport = #"""
{"supportVersion":"frozen-support","requested":{"supportVersion":"frozen-support","film":11,"grain":"offLarge","dynamicRange":400,"colorChrome":3,"colorChromeBlue":2,"whiteBalance":2,"whiteBalanceRed":-4,"whiteBalanceBlue":3,"kelvin":6700,"highlightTenths":-20,"shadowTenths":20,"colorTenths":0,"sharpnessTenths":0,"clarityTenths":0,"noiseReduction":-4,"observedOpaqueTuple":[7,2,1,1],"lensOptimizerRequested":true},"dormantGrainSizeNotSerialized":true,"inactiveKelvinPreserved":true,"lensOptimizerRequested":true,"lensOptimizerEffective":false,"lensOptimizerAdjusted":true,"evidence":"old capture","frozenDigest":"unchanged-frozen-digest","assetID":"photos/asset-42"}
"""#
