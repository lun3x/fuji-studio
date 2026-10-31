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
        if let invalid = draft.standardRecipe.invalidSettings.first {
          Text("Choose a supported value: \(invalid.title).")
            .font(.callout).foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading).padding()
            .accessibilityIdentifier("recipe.editor.validation")
        }
        Form {
          Section("Camera") {
            Picker("Camera", selection: $draft.camera) {
              ForEach(RecipeCameraModel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("recipe.editor.camera")
          }
          Section("Name") {
            TextField("Name", text: $draft.name)
              .autocorrectionDisabled().textInputAutocapitalization(.words)
              .accessibilityIdentifier("recipe.editor.name")
          }
          Section("Look") {
            setting(.film)
            setting(.monochromeWarmCool)
            setting(.monochromeMagentaGreen)
            setting(.dynamicRange)
            setting(.dynamicRangePriority)
            setting(.grain)
            setting(.grainSize)
            setting(.colorChrome)
            setting(.colorChromeBlue)
            setting(.smoothSkin)
          }
          Section("White balance") {
            setting(.whiteBalance)
            temperature
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
            setting(.lensOptimizer)
            setting(.longExposureNoiseReduction)
          }
          Section("Image and recording") {
            setting(.imageSize)
            setting(.aspectRatio)
            setting(.imageQuality)
            setting(.rawRecording)
            setting(.outputFormat)
            setting(.colorSpace)
            setting(.iso)
          }
          let unread = draft.original.snapshot.unreadImportedSettings.filter { draft.isAvailable($0) }
          if !unread.isEmpty {
            Section {
              let names = unread.map(\.title).joined(separator: ", ")
              let unresolved = unread.filter {
                if case .unknown = draft.value(for: $0) { return true }
                return false
              }
              Text(
                unresolved.isEmpty
                  ? "Not read from this camera: \(names). Review these values before saving."
                  : "Not read from this camera: \(names). Choose a value before saving."
              )
              .font(.footnote).foregroundStyle(.secondary)
              .accessibilityIdentifier("recipe.editor.importDefaults")
            }
          }
        }
        .disabled(saving)
        .scrollDismissesKeyboard(.interactively)
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
          .disabled(saving || !draft.canSave)
          .accessibilityLabel("Save")
          .accessibilityIdentifier("recipe.editor.save")
        }
      }
      .onChange(of: draft) { error = nil }
    }
    .interactiveDismissDisabled(saving || draft.hasChanges)
  }

  @ViewBuilder private var temperature: some View {
    if draft.isAvailable(.kelvin) {
      let invalid = !draft.isChoiceAvailable(draft.value(for: .kelvin), for: .kelvin)
      HStack {
        Text("Temperature (K)")
        TextField("Kelvin", text: $draft.temperature)
          .keyboardType(.numberPad).multilineTextAlignment(.trailing)
          .foregroundStyle(invalid ? Color.red : Color.primary)
          .accessibilityLabel("Temperature in kelvin")
          .accessibilityHint(invalid ? "This value is unavailable. Choose a supported temperature." : "")
          .accessibilityIdentifier("recipe.editor.temperature")
        if invalid {
          Image(systemName: "exclamationmark.circle")
            .foregroundStyle(.red)
            .accessibilityLabel("Unavailable temperature")
            .accessibilityIdentifier("recipe.editor.temperature.unavailable")
        }
        NavigationLink {
          RecipeTemperatureChoices(draft: $draft)
        } label: {
          Text("Values")
        }
        .accessibilityIdentifier("recipe.editor.setting.kelvin")
      }
    }
  }

  @ViewBuilder private func setting(_ field: RecipeSettingID) -> some View {
    if draft.isAvailable(field) {
      let selected = draft.value(for: field)
      let invalid = !draft.isChoiceAvailable(selected, for: field)
      let title = field == .grain ? "Grain effect" : field.title
      Menu {
        ForEach(draft.choices(for: field), id: \.value) { choice in
          Button {
            guard draft.isChoiceAvailable(choice.value, for: field) else { return }
            draft.setValue(choice.value, for: field)
          } label: {
            if choice.value == selected {
              Label(field.label(for: choice.value), systemImage: "checkmark")
            } else {
              Text(field.label(for: choice.value))
            }
          }
        }
      } label: {
        HStack {
          Text(title).foregroundStyle(Color.primary)
          Spacer()
          Text(field.label(for: selected))
          if invalid { Image(systemName: "exclamationmark.circle").accessibilityHidden(true) }
          Image(systemName: "chevron.up.chevron.down").font(.caption)
        }
        .foregroundStyle(invalid ? Color.red : Color.accentColor)
      }
      .accessibilityLabel("\(title), \(field.label(for: selected))")
      .accessibilityValue(invalid ? "Unavailable" : "")
      .accessibilityHint(invalid ? "Choose an available value before saving." : "")
      .accessibilityIdentifier(
        "recipe.editor.setting.\(field == .grain ? "grainEffect" : field.rawValue)")
    }
  }

  private func save() {
    guard !saving, draft.canSave else { return }
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

private struct RecipeTemperatureChoices: View {
  @Binding var draft: PhoneRecipeDraft
  @State private var search = ""
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    List {
      TextField("Search Kelvin", text: $search).keyboardType(.numberPad)
        .accessibilityIdentifier("recipe.editor.temperature.search")
      ForEach(
        draft.choices(for: .kelvin).filter { search.isEmpty || $0.label.contains(search) },
        id: \.value
      ) { choice in
        Button {
          draft.setValue(choice.value, for: .kelvin)
          dismiss()
        } label: {
          HStack {
            Text(choice.label)
            Spacer()
            if draft.value(for: .kelvin) == choice.value { Image(systemName: "checkmark") }
          }
        }
        .foregroundStyle(Color.primary)
      }
    }
    .navigationTitle("Temperature")
  }
}
