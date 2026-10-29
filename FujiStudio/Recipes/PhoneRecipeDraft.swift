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
    case .invalidSettings:
      "These imported settings cannot be changed. You can still rename the recipe."
    case .unsupportedContext:
      "Settings from this camera aren’t editable yet. You can still change the name."
    case .missingRecipe: "This phone recipe was deleted. Close the editor to continue."
    case .staleRecipe:
      "This recipe changed while you were editing. Close and reopen the editor to use its latest settings."
    case .invalidValue(let title): "Choose a supported value for \(title.lowercased())."
    case .conversionUnavailable:
      "These settings can’t be converted. Replace unsupported values before saving settings."
    }
  }
}

/// Edits explicit semantic values while preserving every untouched native byte.
struct PhoneRecipeDraft: Sendable, Equatable {
  let original: PhoneRecipe
  private let codecs: RecipeCodecRegistry
  private let initialValues: [RecipeSettingID: RecipeSettingValue]
  let capabilities: CameraCapabilities?
  var name: String
  var temperature: String
  private var changedValues: [RecipeSettingID: RecipeSettingValue] = [:]
  private var rememberedGrainSize: GrainSize?
  init(recipe: PhoneRecipe, codecs: RecipeCodecRegistry = RecipeCodecRegistry()) {
    original = recipe
    self.codecs = codecs
    name = recipe.snapshot.name
    initialValues = (try? codecs.editableValues(recipe.snapshot)) ?? [:]
    capabilities = try? codecs.capabilities(for: recipe.snapshot.cameraContext)
    if case .integer(let kelvin) = initialValues[.kelvin] {
      temperature = String(kelvin)
    } else {
      temperature = ""
    }
  }
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.original == rhs.original && lhs.name == rhs.name && lhs.temperature == rhs.temperature
      && lhs.changedValues == rhs.changedValues
      && lhs.rememberedGrainSize == rhs.rememberedGrainSize
  }
  var supportsSettingsEditing: Bool { capabilities != nil && !initialValues.isEmpty }
  var hasChanges: Bool {
    name != original.snapshot.name || !changedValues.isEmpty || temperature != initialTemperature
  }
  private var initialTemperature: String {
    if case .integer(let kelvin) = initialValues[.kelvin] { return String(kelvin) }
    return ""
  }
  func value(for setting: RecipeSettingID) -> RecipeSettingValue? {
    changedValues[setting] ?? initialValues[setting]
  }
  func choices(for setting: RecipeSettingID) -> [SettingChoice] {
    guard let c = capabilities?.settings[setting], c.support == .supported else { return [] }
    if !c.editableChoices.isEmpty {
      return c.editableChoices.filter { c.accepts($0.value, rendering: true) }.sorted {
        guard case .integer(let lhs) = $0.value, case .integer(let rhs) = $1.value else {
          return false
        }
        return lhs > rhs
      }
    }
    guard let min = c.minimum, let max = c.maximum, let step = c.step, step > 0 else { return [] }
    return stride(from: min, through: max, by: step).reversed().map {
      .init(value: .integer($0), label: setting.label(for: .integer($0)))
    }
  }
  var grain: GrainSettings? {
    if case .grain(var grain) = value(for: .grain) {
      if grain.strength == .off, grain.size != nil, let rememberedGrainSize {
        grain.size = rememberedGrainSize
      }
      return grain
    }
    return nil
  }
  private var grainChoices: [GrainSettings] {
    choices(for: .grain).compactMap {
      if case .grain(let grain) = $0.value { return grain }
      return nil
    }
  }
  var grainEffects: [GrainStrength] {
    GrainStrength.allCases.filter { effect in grainChoices.contains { $0.strength == effect } }
  }
  var grainSizes: [GrainSize] {
    GrainSize.allCases.filter { size in
      grainChoices.contains { $0.strength == grain?.strength && $0.size == size }
    }
  }
  mutating func setGrainEffect(_ effect: GrainStrength) {
    let candidates = grainChoices.filter { $0.strength == effect }
    guard let selected = candidates.first(where: { $0.size == grain?.size }) ?? candidates.first
    else { return }
    if effect == .off {
      rememberedGrainSize = grain?.size
    }
    setValue(.grain(selected), for: .grain)
  }
  mutating func setGrainSize(_ size: GrainSize) {
    guard let grain, grain.strength != .off,
      let selected = grainChoices.first(where: { $0.strength == grain.strength && $0.size == size })
    else { return }
    setValue(.grain(selected), for: .grain)
  }
  mutating func setValue(_ value: RecipeSettingValue, for setting: RecipeSettingID) {
    if value == initialValues[setting] {
      changedValues[setting] = nil
    } else {
      changedValues[setting] = value
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
    var changes = changedValues
    if temperature != initialTemperature {
      guard let kelvin = Int(temperature.trimmingCharacters(in: .whitespacesAndNewlines)),
        capabilities?.settings[.kelvin]?.accepts(.integer(kelvin), rendering: true) == true
      else { throw PhoneRecipeEditingError.invalidTemperature }
      if .integer(kelvin) != initialValues[.kelvin] { changes[.kelvin] = .integer(kelvin) }
    }
    for (id, value) in changes {
      guard supportsSettingsEditing else { throw PhoneRecipeEditingError.unsupportedContext }
      guard capabilities?.settings[id]?.accepts(value, rendering: false) == true,
        capabilities?.settings[id]?.accepts(value, rendering: true) == true
      else {
        throw PhoneRecipeEditingError.invalidValue(id.title)
      }
    }
    if changes.isEmpty && title == source.name { return source }
    let edited: RecipeSnapshot
    if changes.isEmpty {
      edited = source
    } else {
      do { edited = try codecs.encodeEditedValues(changes, preserving: source) } catch {
        throw PhoneRecipeEditingError.invalidSettings
      }
      guard case .supported = codecs.assess(edited).renderingSupport else {
        throw PhoneRecipeEditingError.conversionUnavailable
      }
    }
    return RecipeSnapshot(
      id: changes.isEmpty ? UUID() : edited.id, slot: source.slot, name: title,
      importedName: source.importedName,
      importedSettings: edited.importedSettings, settingsDigest: edited.settingsDigest,
      cameraContext: source.cameraContext,
      importedAt: source.importedAt, renderingIssues: edited.renderingIssues,
      copiedFromRecipeID: original.id)
  }
}
