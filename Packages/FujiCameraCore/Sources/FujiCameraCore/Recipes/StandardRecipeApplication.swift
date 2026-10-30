import Foundation

enum StandardRecipeApplicationError: Error, Sendable {
  case unsupportedSetting(RecipeSettingID, RecipeSettingValue)
}

extension RecipeCodecRegistry {
  /// Project only supported active settings. The stored request is never changed by projection.
  public func applicationSettings(_ snapshot: RecipeSnapshot) throws -> RecipeSettings {
    guard RecipeCameraModel(rawValue: snapshot.cameraContext.model) != nil else {
      throw CameraServiceError.unsupportedContext
    }
    let recipe = snapshot.standardRecipe
    let known: Set<UInt16> =
      snapshot.cameraContext.model == "X-E3"
      ? Set(1...14) : Set(0xD18E...0xD1A4)
    guard snapshot.importedSettings.allSatisfy({ known.contains($0.code) }) else {
      throw CameraServiceError.unsupportedSettings
    }
    // Capture intent cannot change an existing RAF. It still needs explicit validation to save.
    if let invalid = recipe.invalidSettings.first(where: { ![.iso, .rawRecording].contains($0) }) {
      throw StandardRecipeApplicationError.unsupportedSetting(invalid, recipe.value(for: invalid))
    }
    func value(_ id: RecipeSettingID) -> RecipeSettingValue { recipe.value(for: id) }
    func integer(_ id: RecipeSettingID) -> Int {
      if case .integer(let n) = value(id) { return n }
      if case .integer(let n) = StandardRecipeCatalog.defaults[id]! { return n }
      return 0
    }
    func effect(_ id: RecipeSettingID) -> EffectStrength {
      if case .effect(let strength) = value(id) { return strength }
      return .off
    }
    let supportedOutput: [RecipeSettingID: [RecipeSettingValue]] = [
      .dynamicRangePriority: [.option(.off)], .smoothSkin: [.effect(.off)],
      .monochromeWarmCool: [.integer(0)], .monochromeMagentaGreen: [.integer(0)],
      .colorSpace: [.option(.sRGB)], .imageSize: [.option(.large)],
      .aspectRatio: [.option(.ratio3x2)], .outputFormat: [.option(.jpeg)],
      .imageQuality: [.option(.fine), .option(.fineRAW)],
      .longExposureNoiseReduction: [.integer(0)],
    ]
    for id in RecipeSettingID.allCases where recipe.isAvailable(id) {
      if let choices = supportedOutput[id], !choices.contains(value(id)) {
        throw StandardRecipeApplicationError.unsupportedSetting(id, value(id))
      }
    }
    guard case .film(let film) = value(.film), case .whiteBalance(let wb) = value(.whiteBalance),
      case .grain(let grain) = value(.grain)
    else { throw CameraServiceError.unsupportedSettings }
    let xt5 = recipe.camera == .xt5
    let size: GrainSize = value(.grainSize) == .option(.large) ? .large : .small
    let settings = RecipeSettings(
      film: film, grain: .init(strength: grain.strength, size: xt5 ? size : nil),
      dynamicRange: integer(.dynamicRange), whiteBalance: wb,
      whiteBalanceRed: integer(.whiteBalanceRed), whiteBalanceBlue: integer(.whiteBalanceBlue),
      kelvin: xt5 || wb == .temperature
        ? (recipe.accepts(value(.kelvin), for: .kelvin) ? integer(.kelvin) : 5000) : nil,
      highlightTenths: integer(.highlight), shadowTenths: integer(.shadow),
      colorTenths: integer(.color), sharpnessTenths: integer(.sharpness),
      noiseReduction: integer(.noiseReduction), colorChrome: xt5 ? effect(.colorChrome) : nil,
      colorChromeBlue: xt5 ? effect(.colorChromeBlue) : nil,
      clarityTenths: xt5 ? integer(.clarity) : nil,
      lensOptimizerRequested: integer(.lensOptimizer) == 1)
    let capabilities = xt5 ? Self.xt5Capabilities : XE3Capabilities.measured
    for (id, v) in settings.values {
      if id == .kelvin && wb != .temperature { continue }
      guard capabilities.settings[id]?.accepts(v, rendering: true) == true else {
        throw StandardRecipeApplicationError.unsupportedSetting(id, v)
      }
    }
    return settings
  }
}
