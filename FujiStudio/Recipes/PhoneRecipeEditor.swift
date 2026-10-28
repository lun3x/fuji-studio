import FujiCameraCore
import SwiftUI

struct PhoneRecipeEditor: View {
    @State private var draft: PhoneRecipeDraft
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    let onSave: (PhoneRecipeDraft) async throws -> Void

    init(recipe: PhoneRecipe, onSave: @escaping (PhoneRecipeDraft) async throws -> Void) {
        _draft = State(initialValue: PhoneRecipeDraft(recipe: recipe)); self.onSave = onSave
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                        .accessibilityIdentifier("recipe.editor.error")
                }
                Form {
                    Section("Name") {
                        TextField("Name", text: $draft.name)
                            .autocorrectionDisabled().textInputAutocapitalization(.words)
                            .accessibilityIdentifier("recipe.editor.name")
                    }
                    if !draft.supportsSettingsEditing {
                        Section { Text(PhoneRecipeEditingError.unsupportedContext.message).foregroundStyle(.secondary) }
                    } else {
                        Section {
                            setting(.film); setting(.dynamicRange); grainSettings
                            setting(.colorChrome); setting(.colorChromeBlue)
                        } header: { Text("Look") }
                        Section("White balance") {
                            setting(.whiteBalance)
                            if draft.value(for: .whiteBalance) == 32775 {
                                if draft.value(for: .kelvin) != nil {
                                    HStack {
                                        Text("Temperature (K)")
                                        TextField("Kelvin", text: $draft.temperature)
                                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                                            .accessibilityLabel("Temperature in kelvin")
                                            .accessibilityIdentifier("recipe.editor.temperature")
                                    }
                                } else { LabeledContent("Temperature", value: "Unavailable") }
                            }
                            setting(.whiteBalanceRed); setting(.whiteBalanceBlue)
                        }
                        Section("Tone and detail") {
                            setting(.highlight); setting(.shadow); setting(.color)
                            setting(.sharpness); setting(.noiseReduction); setting(.clarity)
                        }
                    }
                }
                .disabled(saving)
                .accessibilityIdentifier("recipe.editor.form")
            }
            .navigationTitle("Edit phone recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                        .accessibilityIdentifier("recipe.editor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if saving { ProgressView() } else { Text("Save") }
                    }
                    .disabled(saving || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Save")
                    .accessibilityIdentifier("recipe.editor.save")
                }
            }
            .onChange(of: draft) { error = nil }
        }
        .interactiveDismissDisabled(saving || draft.hasChanges)
    }
    @ViewBuilder private var grainSettings: some View {
        if draft.value(for: .grain) != nil {
            Picker("Grain effect", selection: Binding(get: { draft.grain?.effect },
                set: { if let effect = $0 { draft.setGrainEffect(effect) } })) {
                if draft.grain == nil { Text("Keep current unsupported value").tag(Optional<PhoneRecipeGrain.Effect>.none) }
                ForEach(PhoneRecipeGrain.Effect.allCases) { Text($0.rawValue).tag(Optional($0)) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("recipe.editor.setting.grainEffect")
            Picker("Grain size", selection: Binding(get: { draft.grain?.size },
                set: { if let size = $0 { draft.setGrainSize(size) } })) {
                if draft.grain == nil { Text("Unavailable").tag(Optional<PhoneRecipeGrain.Size>.none) }
                ForEach(PhoneRecipeGrain.Size.allCases) { Text($0.rawValue).tag(Optional($0)) }
            }
            .pickerStyle(.menu)
            .disabled(draft.grain == nil || draft.grain?.effect == .off)
            .accessibilityIdentifier("recipe.editor.setting.grainSize")
        } else {
            LabeledContent("Grain effect", value: "Unavailable")
            LabeledContent("Grain size", value: "Unavailable")
        }
    }
    @ViewBuilder private func setting(_ field: PhoneRecipeSetting) -> some View {
        if let value = draft.value(for: field) {
            Picker(field.title, selection: Binding(get: { draft.value(for: field) ?? value },
                set: { draft.setValue($0, for: field) })) {
                if !field.accepts(value) { Text("Keep current unsupported value").tag(value) }
                ForEach(field.choices) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("recipe.editor.setting.\(field.rawValue)")
        } else { LabeledContent(field.title, value: "Unavailable") }
    }
    private func save() {
        guard !saving else { return }
        saving = true; error = nil
        Task { @MainActor in
            do { try await onSave(draft); dismiss() }
            catch let issue as PhoneRecipeEditingError { error = issue.message }
            catch { self.error = "Couldn’t save changes. Please try again." }
            saving = false
        }
    }
}
