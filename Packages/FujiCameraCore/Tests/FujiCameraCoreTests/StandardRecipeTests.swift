import Foundation
import Testing

@testable import FujiCameraCore

struct StandardRecipeTests {
  @Test func defaultsCoverEverySettingAndSurviveSerialization() throws {
    let recipe = StandardRecipe(camera: .xt5)
    #expect(Set(recipe.values.keys) == Set(RecipeSettingID.allCases))
    #expect(recipe.value(for: .lensOptimizer) == .integer(1))
    #expect(recipe.value(for: .imageQuality) == .option(.fineRAW))
    #expect(recipe.value(for: .rawRecording) == .option(.losslessCompressed))
    #expect(recipe.value(for: .monochromeWarmCool) == .integer(0))
    #expect(recipe.invalidSettings.isEmpty)
    #expect(
      try JSONDecoder().decode(StandardRecipe.self, from: JSONEncoder().encode(recipe)) == recipe)
    for id in RecipeSettingID.allCases {
      #expect(!StandardRecipeCatalog.choices(for: id).isEmpty)
    }
  }

  @Test func cameraChangesKeepUnavailableAndInvalidValuesUntilExplicitlyReplaced() {
    var recipe = StandardRecipe(camera: .xt5)
    recipe.setValue(.film(.realaAce), for: .film)
    recipe.setValue(.integer(15), for: .highlight)
    recipe.setValue(.effect(.strong), for: .colorChrome)
    recipe.setValue(.integer(5310), for: .kelvin)
    recipe.setValue(.whiteBalance(.temperature), for: .whiteBalance)
    recipe.camera = .xe3
    #expect(!recipe.isAvailable(.colorChrome))
    #expect(recipe.value(for: .colorChrome) == .effect(.strong))
    #expect(Set(recipe.invalidSettings) == Set([.film, .highlight, .kelvin]))
    #expect(!recipe.accepts(.integer(15), for: .highlight))
    #expect(recipe.accepts(.integer(10), for: .highlight))
    recipe.camera = .xt5
    #expect(recipe.invalidSettings.isEmpty)
    #expect(recipe.value(for: .highlight) == .integer(15))
    #expect(recipe.value(for: .kelvin) == .integer(5310))
  }

  @Test func monochromaticAxesAreEnabledOnlyForCompatibleFilmsAndRetainTheirValues() {
    var recipe = StandardRecipe(camera: .xt5)
    recipe.setValue(.integer(70), for: .monochromeWarmCool)
    #expect(!recipe.isAvailable(.monochromeWarmCool))
    #expect(recipe.invalidSettings.isEmpty)
    recipe.setValue(.film(.acrosRed), for: .film)
    #expect(recipe.isAvailable(.monochromeWarmCool))
    #expect(recipe.isAvailable(.monochromeMagentaGreen))
    recipe.setValue(.film(.sepia), for: .film)
    #expect(!recipe.isAvailable(.monochromeWarmCool))
    recipe.setValue(.film(.monochrome), for: .film)
    #expect(recipe.value(for: .monochromeWarmCool) == .integer(70))
    recipe.camera = .xe3
    #expect(!recipe.isAvailable(.monochromeWarmCool))
    #expect(recipe.invalidSettings.isEmpty)
  }

  @Test func dependencyRulesPreserveDormantValuesWithoutBlockingSave() {
    var recipe = StandardRecipe(camera: .xt5)
    recipe.setValue(.integer(15), for: .highlight)
    recipe.setValue(.option(.strong), for: .dynamicRangePriority)
    #expect(!recipe.isAvailable(.highlight))
    #expect(!recipe.isAvailable(.dynamicRange))
    recipe.camera = .xe3
    // Priority is absent on X-E3, so manual tone becomes active again.
    #expect(recipe.isAvailable(.highlight))
    #expect(recipe.invalidSettings == [.highlight])
    recipe.setValue(.integer(10), for: .highlight)
    recipe.setValue(.option(.adobeRGB), for: .colorSpace)
    recipe.camera = .xt5
    recipe.setValue(.option(.heif), for: .outputFormat)
    #expect(recipe.invalidSettings.contains(.colorSpace))
    #expect(!recipe.isAvailable(.clarity))
  }

  @Test func grainSizeIsIndependentOfCameraAndStrength() {
    var recipe = StandardRecipe(camera: .xt5)
    recipe.setValue(.option(.large), for: .grainSize)
    #expect(!recipe.isAvailable(.grainSize))
    recipe.setValue(.grain(.init(strength: .strong, size: nil)), for: .grain)
    #expect(recipe.isAvailable(.grainSize))
    recipe.camera = .xe3
    #expect(!recipe.isAvailable(.grainSize))
    #expect(recipe.invalidSettings.isEmpty)
    recipe.camera = .xt5
    #expect(recipe.value(for: .grainSize) == .option(.large))
  }
}
