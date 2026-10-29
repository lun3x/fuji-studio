import Foundation
import Testing

@testable import FujiCameraCore
@testable import FujiStudio

struct PhoneRecipeDraftTests {
  @Test func xt5EditorOffersAndReopensEveryDocumentedSelector() throws {
    let phone = try ProductionProfileFixture().bank.copiedToPhone()
    let original = PhoneRecipeDraft(recipe: phone)
    #expect(original.choices(for: .film).count == 20)
    #expect(original.choices(for: .whiteBalance).count == 14)
    #expect(
      original.choices(for: .dynamicRange).map(\.value)
        == [400, 200, 100, 0].map(RecipeSettingValue.integer))
    #expect(RecipeSettingID.dynamicRange.label(for: .integer(0)) == "Auto")
    for id in [RecipeSettingID.film, .whiteBalance, .dynamicRange] {
      for choice in original.choices(for: id) {
        var draft = PhoneRecipeDraft(recipe: phone)
        draft.setValue(choice.value, for: id)
        let saved = PhoneRecipe(id: phone.id, snapshot: try draft.makeSnapshot())
        let reopened = PhoneRecipeDraft(recipe: saved)
        #expect(reopened.value(for: id) == choice.value)
        #expect(!reopened.hasChanges)
      }
    }
  }
  @Test func xt5TemperatureUsesTenKelvinSteps() throws {
    let phone = try ProductionProfileFixture().bank.copiedToPhone()
    for kelvin in [2500, 5310, 10000] {
      var draft = PhoneRecipeDraft(recipe: phone)
      draft.temperature = String(kelvin)
      let saved = try draft.makeSnapshot()
      #expect(try RecipeCodecRegistry().editableValues(saved)[.kelvin] == .integer(kelvin))
    }
    for kelvin in [2490, 2501, 5301, 10001] {
      var draft = PhoneRecipeDraft(recipe: phone)
      draft.temperature = String(kelvin)
      #expect(throws: PhoneRecipeEditingError.invalidTemperature) { try draft.makeSnapshot() }
    }
  }
  @Test(arguments: [
    WhiteBalanceMode.auto, .daylight, .shade, .fluorescent1, .fluorescent2, .fluorescent3,
    .incandescent, .underwater, .temperature,
  ])
  func calibratedXE3PresetsRemainRenderableAfterOfflineEdits(_ mode: WhiteBalanceMode) throws {
    let phone = try fixtureXE3Recipe().copiedToPhone()
    var draft = PhoneRecipeDraft(recipe: phone)
    draft.setValue(.whiteBalance(mode), for: .whiteBalance)
    draft.setValue(.integer(1), for: .whiteBalanceRed)
    draft.setValue(.integer(2), for: .whiteBalanceBlue)
    let snapshot = try draft.makeSnapshot()
    #expect(RecipeCodecRegistry().assess(snapshot).issues.isEmpty)
    let settings = try RecipeCodecRegistry().requireSettings(snapshot)
    #expect(settings.whiteBalance == mode)
    #expect(settings.whiteBalanceRed == 1 && settings.whiteBalanceBlue == 2)
    #expect(snapshot.copiedFromRecipeID == phone.id)
  }
  @Test func xe3UsesDiscreteKelvinWholeToneStepsAndNoGrainSize() throws {
    let phone = try fixtureXE3Recipe(unknown: true).copiedToPhone()
    var draft = PhoneRecipeDraft(recipe: phone)
    #expect(draft.supportsSettingsEditing)
    #expect(draft.grain?.size == nil)
    #expect(
      draft.choices(for: .kelvin).map(\.value)
        == XE3NativeRecipeFields.kelvin.sorted(by: >).map(RecipeSettingValue.integer))
    #expect(draft.choices(for: .colorChrome).isEmpty && draft.choices(for: .clarity).isEmpty)
    #expect(
      draft.choices(for: .highlight).map(\.value)
        == [40, 30, 20, 10, 0, -10, -20].map(RecipeSettingValue.integer))
    draft.setValue(.integer(2), for: .whiteBalanceRed)
    draft.setGrainEffect(.strong)
    let edited = try draft.makeSnapshot()
    #expect(edited.copiedFromRecipeID == phone.id)
    #expect(edited.importedSettings.first { $0.code == 99 }?.raw == Data([0xaa, 0xbb]))
    #expect(try RecipeCodecRegistry().editableValues(edited)[.whiteBalanceRed] == .integer(2))
    #expect(
      try RecipeCodecRegistry().editableValues(edited)[.grain]
        == .grain(.init(strength: .strong, size: nil)))
    draft.temperature = "5310"
    #expect(throws: PhoneRecipeEditingError.invalidTemperature) { try draft.makeSnapshot() }
  }
  @Test func grainControlsPreserveEachOtherAndRememberSizeWhileOff() throws {
    let original = try ProductionProfileFixture().bank.copiedToPhone()
    var draft = PhoneRecipeDraft(recipe: original)
    #expect(draft.grain == .init(strength: .strong, size: .small))
    draft.setGrainSize(.large)
    #expect(draft.grain == .init(strength: .strong, size: .large))
    draft.setGrainEffect(.weak)
    #expect(draft.grain == .init(strength: .weak, size: .large))
    draft.setGrainEffect(.off)
    draft.setGrainSize(.small)
    #expect(draft.grain == .init(strength: .off, size: .large))
    let saved = PhoneRecipe(id: original.id, snapshot: try draft.makeSnapshot())
    var reopened = PhoneRecipeDraft(recipe: saved)
    #expect(reopened.grain == .init(strength: .off, size: .large))
    reopened.setGrainEffect(.strong)
    reopened.setGrainSize(.small)
    #expect(reopened.grain == .init(strength: .strong, size: .small))
  }
  @Test func unknownGrainStaysUnchangedUntilExplicitlyEdited() throws {
    let f = try ProductionProfileFixture()
    var p = f.properties
    p[0xD195] = 99
    let original = try f.bank(p).copiedToPhone()
    var draft = PhoneRecipeDraft(recipe: original)
    #expect(draft.grain == nil)
    draft.setGrainSize(.large)
    #expect(!draft.hasChanges)
    #expect(try draft.makeSnapshot() == original.snapshot)
    draft.setGrainEffect(.weak)
    #expect(draft.grain == .init(strength: .weak, size: .small))
    #expect(
      try draft.makeSnapshot().importedSettings.first { $0.code == 0xD195 }?.raw
        == ProtocolProbeFixtures.word(1))
  }
  @Test func allSemanticGrainChoicesPreserveOtherBytes() throws {
    let original = try ProductionProfileFixture().bank.copiedToPhone()
    for choice in PhoneRecipeDraft(recipe: original).choices(for: .grain) {
      var draft = PhoneRecipeDraft(recipe: original)
      draft.setValue(choice.value, for: .grain)
      let snapshot = try draft.makeSnapshot()
      #expect(
        PhoneRecipeDraft(recipe: .init(id: original.id, snapshot: snapshot)).value(for: .grain)
          == choice.value)
      #expect(
        snapshot.importedSettings.filter { $0.code != 0xD195 }
          == original.snapshot.importedSettings.filter { $0.code != 0xD195 })
    }
  }
  @Test func renameKeepsFrozenDigest() throws {
    let f = try ProductionProfileFixture()
    var p = f.properties
    p[0xD192] = 99
    p[0xD1A4] = 2
    let original = try f.bank(p).copiedToPhone()
    var draft = PhoneRecipeDraft(recipe: original)
    draft.name = "Renamed unsupported"
    let changed = try draft.makeSnapshot()
    #expect(changed.settingsDigest == original.snapshot.settingsDigest)
    #expect(changed.importedSettings == original.snapshot.importedSettings)
    #expect(changed.id != original.snapshot.id && changed.copiedFromRecipeID == original.id)
    #expect(try PhoneRecipeDraft(recipe: original).makeSnapshot() == original.snapshot)
    draft.setValue(.integer(10), for: .sharpness)
    #expect(
      try draft.makeSnapshot().importedSettings.first { $0.code == 0xD192 }?.raw
        == ProtocolProbeFixtures.word(99))
  }
  @Test func changedSettingsProduceValidSnapshotAndPreserveUntouchedValues() throws {
    let original = try ProductionProfileFixture().bank.copiedToPhone()
    var draft = PhoneRecipeDraft(recipe: original)
    draft.name = "  My daylight 🌤  "
    draft.setValue(.film(.provia), for: .film)
    draft.setValue(.integer(-5), for: .highlight)
    draft.setValue(.integer(3), for: .noiseReduction)
    draft.setValue(.whiteBalance(.temperature), for: .whiteBalance)
    draft.temperature = "5200"
    let updated = try draft.makeSnapshot()
    let settings = try updated.settings(using: RecipeCodecRegistry())
    #expect(updated.name == "My daylight 🌤" && updated.id != original.snapshot.id)
    #expect(
      settings.film == .provia && settings.highlightTenths == -5 && settings.noiseReduction == 3)
    #expect(settings.whiteBalance == .temperature && settings.kelvin == 5200)
    let changed: Set<UInt16> = [0xD192, 0xD19D, 0xD1A1, 0xD199, 0xD19C]
    #expect(
      updated.importedSettings.filter { !changed.contains($0.code) }
        == original.snapshot.importedSettings.filter { !changed.contains($0.code) })
  }
  @Test func invalidNewValuesAreRejectedWithoutChangingOriginal() throws {
    let original = try ProductionProfileFixture().bank.copiedToPhone()
    var empty = PhoneRecipeDraft(recipe: original)
    empty.name = " \n "
    #expect(throws: PhoneRecipeEditingError.emptyName) { try empty.makeSnapshot() }
    for value in ["", "abc", "2499", "10001"] {
      var draft = PhoneRecipeDraft(recipe: original)
      draft.temperature = value
      #expect(throws: PhoneRecipeEditingError.invalidTemperature) { try draft.makeSnapshot() }
    }
    var invalid = PhoneRecipeDraft(recipe: original)
    invalid.setValue(.integer(300), for: .dynamicRange)
    #expect(throws: PhoneRecipeEditingError.self) { try invalid.makeSnapshot() }
    #expect(try original.snapshot.settings(using: RecipeCodecRegistry()).dynamicRange == 400)
  }
  @Test func offeredChoicesMatchOfflineCapabilities() throws {
    let original = try ProductionProfileFixture().bank.copiedToPhone()
    let draft = PhoneRecipeDraft(recipe: original)
    for id in RecipeSettingID.allCases.filter({ $0 != .kelvin }) {
      for choice in draft.choices(for: id) {
        var changed = draft
        changed.setValue(choice.value, for: id)
        let snapshot = try changed.makeSnapshot()
        #expect(
          PhoneRecipeDraft(recipe: .init(id: original.id, snapshot: snapshot)).value(for: id)
            == choice.value)
      }
    }
  }
  @Test func untouchedPaddedNameDoesNotCreateRevision() throws {
    let r = try ProductionProfileFixture().bank
    let camera = try XT5RecipeCodec.recipe(
      slot: r.slot, nameData: ProtocolProbeFixtures.string("  My look  "),
      properties: Dictionary(uniqueKeysWithValues: r.importedSettings.map { ($0.code, $0.raw) }),
      context: r.cameraContext, importedAt: r.importedAt)
    let original = camera.copiedToPhone()
    var draft = PhoneRecipeDraft(recipe: original)
    #expect(!draft.hasChanges)
    #expect(try draft.makeSnapshot() == original.snapshot)
    draft.setValue(.film(.provia), for: .film)
    #expect(try draft.makeSnapshot().name == original.snapshot.name)
  }
}
