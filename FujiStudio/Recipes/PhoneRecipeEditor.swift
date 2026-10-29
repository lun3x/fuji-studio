import FujiCameraCore
import SwiftUI

struct PhoneRecipeEditor: View {
  @State private var draft: PhoneRecipeDraft
  @State private var saving = false
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss
  let onSave: (PhoneRecipeDraft) async throws -> Void

  init(recipe: PhoneRecipe, onSave: @escaping (PhoneRecipeDraft) async throws -> Void) {
    _draft = State(initialValue: PhoneRecipeDraft(recipe: recipe))
    self.onSave = onSave
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
            Section {
              Text(PhoneRecipeEditingError.unsupportedContext.message).foregroundStyle(.secondary)
            }
          } else {
            Section {
              setting(.film)
              setting(.dynamicRange)
              grainSettings
              setting(.colorChrome)
              setting(.colorChromeBlue)
            } header: {
              Text("Look")
            }
            Section("White balance") {
              setting(.whiteBalance)
              if draft.value(for: .whiteBalance) == .whiteBalance(.temperature) {
                if draft.capabilities?.settings[.kelvin]?.editableChoices.isEmpty == false {
                  setting(.kelvin)
                } else {
                  HStack {
                    Text("Temperature (K)")
                    TextField("Kelvin", text: $draft.temperature)
                      .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                      .accessibilityLabel("Temperature in kelvin")
                      .accessibilityIdentifier("recipe.editor.temperature")
                  }
                }
              }
              setting(.whiteBalanceRed)
              setting(.whiteBalanceBlue)
            }
            Section("Tone and detail") {
              setting(.highlight)
              setting(.shadow)
              setting(.color)
              setting(.sharpness)
              setting(.noiseReduction)
              setting(.clarity)
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
    if draft.capabilities?.settings[.grain]?.support == .supported {
      Picker(
        "Grain effect",
        selection: Binding(
          get: { draft.grain?.strength },
          set: { if let effect = $0 { draft.setGrainEffect(effect) } })
      ) {
        if let effect = draft.grain?.strength, !draft.grainEffects.contains(effect) {
          Text("\(effect.rawValue.capitalized) (unavailable for conversion)")
            .tag(Optional(effect)).disabled(true)
        } else if draft.grain == nil {
          Text("Keep current unsupported value").tag(Optional<GrainStrength>.none)
        }
        ForEach(draft.grainEffects, id: \.self) {
          Text($0.rawValue.capitalized).tag(Optional($0))
        }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier("recipe.editor.setting.grainEffect")
      if draft.choices(for: .grain).contains(where: {
        if case .grain(let g) = $0.value { return g.size != nil }
        return false
      }) {
        Picker(
          "Grain size",
          selection: Binding(
            get: { draft.grain?.size },
            set: { if let size = $0 { draft.setGrainSize(size) } })
        ) {
          if let size = draft.grain?.size, !draft.grainSizes.contains(size) {
            Text(size.rawValue.capitalized).tag(Optional(size)).disabled(true)
          } else if draft.grain == nil {
            Text("Unavailable").tag(Optional<GrainSize>.none)
          }
          ForEach(draft.grainSizes, id: \.self) {
            Text($0.rawValue.capitalized).tag(Optional($0))
          }
        }
        .pickerStyle(.menu)
        .disabled(draft.grain == nil || draft.grain?.strength == .off)
        .accessibilityIdentifier("recipe.editor.setting.grainSize")
      }
    }
  }
  @ViewBuilder private func setting(_ field: RecipeSettingID) -> some View {
    if let capability = draft.capabilities?.settings[field], capability.support == .supported {
      let choices = draft.choices(for: field)
      Picker(
        field.title,
        selection: Binding(
          get: { draft.value(for: field) },
          set: { if let value = $0 { draft.setValue(value, for: field) } })
      ) {
        if let value = draft.value(for: field), !choices.contains(where: { $0.value == value }) {
          Text("\(field.label(for: value)) (unavailable for conversion)")
            .tag(Optional(value)).disabled(true)
        } else if draft.value(for: field) == nil {
          Text("Keep current unsupported value").tag(Optional<RecipeSettingValue>.none)
        }
        ForEach(choices, id: \.value) { Text(field.label(for: $0.value)).tag(Optional($0.value)) }
      }
      .pickerStyle(.menu)
      .accessibilityIdentifier("recipe.editor.setting.\(field.rawValue)")
    }
  }
  private func save() {
    guard !saving else { return }
    saving = true
    error = nil
    Task { @MainActor in
      do {
        try await onSave(draft)
        dismiss()
      } catch let issue as PhoneRecipeEditingError { error = issue.message } catch {
        self.error = "Couldn’t save changes. Please try again."
      }
      saving = false
    }
  }
}
