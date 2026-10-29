import Foundation
import FujiCameraCore

enum PhoneRecipeEditingError: Error, Sendable, Equatable {
  case emptyName, invalidTemperature, invalidSettings, unsupportedContext, missingRecipe,
    staleRecipe
  case invalidValue(String)
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
    if !c.editableChoices.isEmpty { return c.editableChoices }
    guard let min = c.minimum, let max = c.maximum, let step = c.step, step > 0 else { return [] }
    return stride(from: min, through: max, by: step).map {
      .init(value: .integer($0), label: setting.label(for: .integer($0)))
    }
  }
  var grain: GrainSettings? {
    if case .grain(let grain) = value(for: .grain) { return grain }
    return nil
  }
  mutating func setGrainEffect(_ effect: GrainStrength) {
    let size =
      grain?.size
      ?? choices(for: .grain).compactMap {
        if case .grain(let g) = $0.value { return g.size }
        return nil
      }.first
    setValue(.grain(.init(strength: effect, size: size)), for: .grain)
  }
  mutating func setGrainSize(_ size: GrainSize) {
    guard let grain, grain.size != nil, grain.strength != .off else { return }
    setValue(.grain(.init(strength: grain.strength, size: size)), for: .grain)
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
        capabilities?.settings[.kelvin]?.accepts(.integer(kelvin), rendering: false) == true
      else { throw PhoneRecipeEditingError.invalidTemperature }
      if .integer(kelvin) != initialValues[.kelvin] { changes[.kelvin] = .integer(kelvin) }
    }
    for (id, value) in changes {
      guard supportsSettingsEditing else { throw PhoneRecipeEditingError.unsupportedContext }
      guard capabilities?.settings[id]?.accepts(value, rendering: false) == true else {
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
