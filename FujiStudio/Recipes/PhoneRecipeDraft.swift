import Foundation
import FujiCameraCore

enum PhoneRecipeEditingError: Error, Sendable, Equatable {
  case emptyName, invalidTemperature, invalidSettings, unsupportedContext, missingRecipe,
    staleRecipe
  case invalidValue(String)
  case conversionUnavailable
  var message: String {
    switch self {
    case .emptyName: "Enter a name for this recipe."
    case .invalidTemperature: "Choose a temperature supported by this camera."
    case .invalidSettings: "Choose valid settings before saving this recipe."
    case .unsupportedContext: "Choose a supported camera for this recipe."
    case .missingRecipe: "This phone recipe was deleted. Close the editor to continue."
    case .staleRecipe:
      "This recipe changed while you were editing. Close and reopen the editor to use its latest settings."
    case .invalidValue(let title): "Choose a supported value for \(title.lowercased())."
    case .conversionUnavailable: "Conversion is unavailable for these settings."
    }
  }
}

/// The camera changes availability, never the complete stored request.
struct PhoneRecipeDraft: Sendable, Equatable {
  let original: PhoneRecipe
  private var recipe: StandardRecipe
  var name: String
  var temperature: String
  private let initialTemperature: String

  init(recipe: PhoneRecipe, codecs: RecipeCodecRegistry = RecipeCodecRegistry()) {
    original = recipe
    self.recipe = recipe.snapshot.standardRecipe
    name = recipe.snapshot.name
    if case .integer(let n) = recipe.snapshot.standardRecipe.value(for: .kelvin) {
      temperature = String(n)
    } else {
      temperature = ""
    }
    initialTemperature = temperature
  }
  var camera: RecipeCameraModel {
    get { recipe.camera }
    set { recipe.camera = newValue }
  }
  var capabilities: CameraCapabilities? {
    camera == .xt5 ? RecipeCodecRegistry.xt5Capabilities : XE3Capabilities.measured
  }
  var supportsSettingsEditing: Bool {
    RecipeCameraModel(rawValue: original.snapshot.cameraContext.model) != nil
  }
  var standardRecipe: StandardRecipe {
    var result = recipe
    if temperature != initialTemperature
      || recipe.value(for: .kelvin) != original.snapshot.standardRecipe.value(for: .kelvin)
    {
      let trimmed = temperature.trimmingCharacters(in: .whitespacesAndNewlines)
      result.setValue(
        Int(trimmed).map(RecipeSettingValue.integer) ?? .unknown(trimmed), for: .kelvin)
    }
    return result
  }
  var hasChanges: Bool {
    name != original.snapshot.name || standardRecipe != original.snapshot.standardRecipe
      || temperature != initialTemperature
  }
  var canSave: Bool {
    supportsSettingsEditing && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && standardRecipe.invalidSettings.isEmpty
  }
  func value(for setting: RecipeSettingID) -> RecipeSettingValue {
    standardRecipe.value(for: setting)
  }
  func choices(for setting: RecipeSettingID) -> [SettingChoice] {
    StandardRecipeCatalog.choices(for: setting)
  }
  func isAvailable(_ setting: RecipeSettingID) -> Bool { standardRecipe.isAvailable(setting) }
  func isChoiceAvailable(_ value: RecipeSettingValue, for setting: RecipeSettingID) -> Bool {
    standardRecipe.accepts(value, for: setting)
  }
  var grain: GrainSettings? {
    guard case .grain(let grain) = value(for: .grain) else { return nil }
    let size: GrainSize = value(for: .grainSize) == .option(.large) ? .large : .small
    return .init(strength: grain.strength, size: size)
  }
  var grainEffects: [GrainStrength] { GrainStrength.allCases }
  var grainSizes: [GrainSize] { GrainSize.allCases }
  mutating func setGrainEffect(_ effect: GrainStrength) {
    setValue(.grain(.init(strength: effect, size: nil)), for: .grain)
  }
  mutating func setGrainSize(_ size: GrainSize) {
    setValue(.option(size == .small ? .small : .large), for: .grainSize)
  }
  mutating func setValue(_ value: RecipeSettingValue, for setting: RecipeSettingID) {
    recipe.setValue(value, for: setting)
    if setting == .kelvin {
      if case .integer(let n) = value { temperature = String(n) } else { temperature = "" }
    }
  }
  func makeSnapshot() throws -> RecipeSnapshot {
    let source = original.snapshot
    guard source.copiedFromRecipeID == original.id else {
      throw PhoneRecipeEditingError.invalidSettings
    }
    let title = name == source.name ? name : name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PhoneRecipeEditingError.emptyName
    }
    guard supportsSettingsEditing else { throw PhoneRecipeEditingError.unsupportedContext }
    if let invalid = standardRecipe.invalidSettings.first {
      if invalid == .kelvin { throw PhoneRecipeEditingError.invalidTemperature }
      throw PhoneRecipeEditingError.invalidValue(invalid.title)
    }
    if !hasChanges { return source }
    return source.replacingStandardRecipe(standardRecipe, name: title)
  }
}
