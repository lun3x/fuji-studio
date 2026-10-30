import Foundation
import Testing

@testable import FujiCameraCore

struct StandardRecipeConversionTests {
  @Test func invalidDormantTemperatureDoesNotEnterTheConversionProfile() throws {
    let f = try ProductionProfileFixture()
    var recipe = f.bank.standardRecipe
    recipe.setValue(.integer(Int.max), for: .kelvin)
    #expect(recipe.invalidSettings.isEmpty)
    let snapshot = f.bank.replacingStandardRecipe(recipe, name: f.bank.name)
    #expect(try RecipeCodecRegistry().applicationSettings(snapshot).kelvin == 5000)
  }
  @Test func nativeImportOverlaysSemanticValuesAndUsesDefaultsForAbsentFeatures() throws {
    let xt5 = try ProductionProfileFixture().bank
    #expect(xt5.standardRecipe.value(for: .lensOptimizer) == .integer(1))
    #expect(xt5.standardRecipe.value(for: .imageQuality) == .option(.fine))
    #expect(xt5.standardRecipe.value(for: .colorSpace) == .option(.sRGB))
    let xe3 = try XE3BackupRecipeCodec.decode(
      syntheticXE3Backup(), context: xe3RecipeContext(), importedAt: Date()
    ).recipes[0]
    #expect(xe3.standardRecipe.value(for: .colorChrome) == .effect(.off))
    #expect(xe3.standardRecipe.value(for: .grainSize) == .option(.small))
    #expect(xe3.standardRecipe.value(for: .rawRecording) == .option(.losslessCompressed))
    #expect(xe3.standardRecipe.values.keys.count == RecipeSettingID.allCases.count)
  }

  @Test func canonicalCopyRetargetsWithoutSourceModelBytesAndRetainsProvenance() throws {
    let imported = try ProductionProfileFixture().bank
    var standard = StandardRecipe(camera: .xe3)
    standard.setValue(.effect(.strong), for: .colorChrome)
    standard.setValue(.option(.large), for: .grainSize)
    standard.setValue(.integer(100), for: .dynamicRange)
    let copy = imported.copiedToPhone().snapshot.replacingStandardRecipe(
      standard, name: "Other camera")
    #expect(copy.cameraContext == imported.cameraContext)
    #expect(copy.targetCamera == .xe3)
    #expect(copy.copiedFromRecipeID == imported.id)
    let settings = try RecipeCodecRegistry().applicationSettings(copy)
    #expect(settings.colorChrome == nil && settings.grain.size == nil)
    #expect(copy.standardRecipe.value(for: .colorChrome) == .effect(.strong))
    let reopened = try JSONDecoder().decode(RecipeSnapshot.self, from: JSONEncoder().encode(copy))
    #expect(reopened.standardRecipe == standard)
    #expect(try RecipeCodecRegistry().applicationSettings(reopened) == settings)
    #expect(copy.settingsDigest != imported.settingsDigest)
  }

  @Test func unknownAvailableNativeValuesRequireExplicitReplacement() throws {
    let f = try ProductionProfileFixture()
    var properties = f.properties
    properties[0xD192] = 99
    let imported = try f.bank(properties)
    #expect(imported.standardRecipe.invalidSettings.contains(.film))
    #expect(throws: (any Error).self) { try RecipeCodecRegistry().applicationSettings(imported) }
    var repaired = imported.standardRecipe
    repaired.setValue(.film(.provia), for: .film)
    #expect(
      try RecipeCodecRegistry().applicationSettings(
        imported.replacingStandardRecipe(repaired, name: imported.name)
      ).film == .provia)
  }

  @Test func changingOnlyDormantMonochromaticValuesDoesNotAffectColourFilmApplication() throws {
    let imported = try ProductionProfileFixture().bank
    var recipe = imported.standardRecipe
    recipe.setValue(.integer(110), for: .monochromeWarmCool)
    let changed = imported.replacingStandardRecipe(recipe, name: imported.name)
    #expect(
      try RecipeCodecRegistry().applicationSettings(changed)
        == RecipeCodecRegistry().applicationSettings(imported))
    recipe.setValue(.film(.acros), for: .film)
    #expect(throws: (any Error).self) {
      try RecipeCodecRegistry().applicationSettings(
        imported.replacingStandardRecipe(recipe, name: imported.name))
    }
  }
}
