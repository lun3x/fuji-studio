import Foundation

enum PhoneRecipeEditingError: Error, Sendable, Equatable {
    case emptyName, invalidTemperature, invalidSettings, unsupportedContext, missingRecipe, staleRecipe
    case invalidValue(String)
    var message: String {
        switch self {
        case .emptyName: "Enter a name for this recipe."
        case .invalidTemperature: "Enter a temperature from 2500 to 10000 K."
        case .invalidSettings: "These imported settings cannot be changed. You can still rename the recipe."
        case .unsupportedContext: "Settings from this camera aren’t editable yet. You can still change the name."
        case .missingRecipe: "This phone recipe was deleted. Close the editor to continue."
        case .staleRecipe: "This recipe changed while you were editing. Close and reopen the editor to use its latest settings."
        case .invalidValue(let title): "Choose a supported value for \(title.lowercased())."
        }
    }
}

/// Edits only explicitly changed values; opening an unsupported import never normalizes it.
struct PhoneRecipeDraft: Sendable, Equatable {
    let original: PhoneRecipe
    var name: String
    var temperature: String
    private var changedValues: [PhoneRecipeSetting: UInt16] = [:]
    init(recipe: PhoneRecipe) {
        original = recipe; name = recipe.snapshot.name
        temperature = Self.word(.kelvin, in: recipe.snapshot).map(String.init) ?? ""
    }
    var supportsSettingsEditing: Bool {
        let context = original.snapshot.cameraContext
        return context.model == "X-T5" && context.firmware == "4.31" && context.capability == "X-T5_0200"
    }
    var hasChanges: Bool {
        name != original.snapshot.name || !changedValues.isEmpty || temperature != initialTemperature
    }
    private var initialTemperature: String { Self.word(.kelvin, in: original.snapshot).map(String.init) ?? "" }
    func value(for setting: PhoneRecipeSetting) -> UInt16? { changedValues[setting] ?? Self.word(setting, in: original.snapshot) }
    mutating func setValue(_ value: UInt16, for setting: PhoneRecipeSetting) {
        if value == Self.word(setting, in: original.snapshot) { changedValues[setting] = nil }
        else { changedValues[setting] = value }
    }
    func makeSnapshot() throws -> RecipeSnapshot {
        let source = original.snapshot
        guard source.copiedFromRecipeID == original.id else { throw PhoneRecipeEditingError.invalidSettings }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw PhoneRecipeEditingError.emptyName }
        var changes = changedValues
        if temperature != initialTemperature {
            guard let kelvin = UInt16(temperature.trimmingCharacters(in: .whitespacesAndNewlines)),
                  PhoneRecipeSetting.kelvin.accepts(kelvin) else { throw PhoneRecipeEditingError.invalidTemperature }
            if kelvin != Self.word(.kelvin, in: source) { changes[.kelvin] = kelvin }
        }
        if !changes.isEmpty {
            guard supportsSettingsEditing else { throw PhoneRecipeEditingError.unsupportedContext }
            for (setting, value) in changes {
                guard Self.word(setting, in: source) != nil, setting.accepts(value) else {
                    throw PhoneRecipeEditingError.invalidValue(setting.title)
                }
            }
        }
        if changes.isEmpty {
            if title == source.name { return source }
            return RecipeSnapshot(id: UUID(), slot: source.slot, name: title, importedName: source.importedName,
                importedSettings: source.importedSettings, settingsDigest: source.settingsDigest,
                cameraContext: source.cameraContext, importedAt: source.importedAt,
                renderingIssues: source.renderingIssues, copiedFromRecipeID: original.id)
        }
        let settings = source.importedSettings.map { property in
            guard let change = changes.first(where: { $0.key.code == property.code })?.value else { return property }
            return ImportedRecipeProperty(code: property.code, raw: Data([UInt8(truncatingIfNeeded: change), UInt8(change >> 8)]))
        }
        guard Set(settings.map(\.code)).count == settings.count else { throw PhoneRecipeEditingError.invalidSettings }
        let assessed: RecipeSnapshot
        do {
            assessed = try XT5RecipeCodec.recipe(slot: source.slot, nameData: source.importedName,
                properties: Dictionary(uniqueKeysWithValues: settings.map { ($0.code, $0.raw) }),
                context: source.cameraContext, importedAt: source.importedAt)
        } catch { throw PhoneRecipeEditingError.invalidSettings }
        return RecipeSnapshot(id: assessed.id, slot: source.slot, name: title, importedName: source.importedName,
            importedSettings: assessed.importedSettings, settingsDigest: assessed.settingsDigest,
            cameraContext: source.cameraContext, importedAt: source.importedAt,
            renderingIssues: assessed.renderingIssues, copiedFromRecipeID: original.id)
    }
    private static func word(_ setting: PhoneRecipeSetting, in snapshot: RecipeSnapshot) -> UInt16? {
        let properties = snapshot.importedSettings.filter { $0.code == setting.code }
        guard properties.count == 1, let data = properties.first?.raw, data.count == 2 else { return nil }
        return UInt16(data[data.startIndex]) | UInt16(data[data.startIndex + 1]) << 8
    }
}
