import Foundation
import Testing

@testable import FujiCameraCore
@testable import FujiStudio

struct PhoneRecipeDraftTests {
  @Test func unreadXE3ISORequiresAnExplicitChoiceBeforeSaving() throws {
    let phone = try fixtureXE3Recipe().copiedToPhone()
    var draft = PhoneRecipeDraft(recipe: phone)
    #expect(!draft.canSave)
    #expect(throws: PhoneRecipeEditingError.invalidValue("ISO")) { try draft.makeSnapshot() }
    draft.setValue(.option(.auto1), for: .iso)
    #expect(draft.canSave)
    #expect(try draft.makeSnapshot().standardRecipe.value(for: .iso) == .option(.auto1))
  }
  @Test func manualTemperatureCanReturnToOriginalAfterChoosingAnotherValue() throws {
    let phone = try ProductionProfileFixture().bank.copiedToPhone()
    var draft = PhoneRecipeDraft(recipe: phone)
    let initial = draft.temperature
    draft.setValue(.integer(5000), for: .kelvin)
    draft.temperature = initial
    #expect(draft.value(for: .kelvin) == phone.snapshot.standardRecipe.value(for: .kelvin))
  }
  @Test func cameraSwitchKeepsInvalidSelectionsAndDisablesSaveUntilRepaired() throws {
    let phone = try ProductionProfileFixture().bank.copiedToPhone()
    var draft = PhoneRecipeDraft(recipe: phone)
    draft.setValue(.film(.realaAce), for: .film)
    draft.setValue(.integer(15), for: .highlight)
    draft.camera = .xe3
    #expect(draft.value(for: .film) == .film(.realaAce))
    #expect(draft.value(for: .highlight) == .integer(15))
    #expect(!draft.canSave)
    #expect(throws: PhoneRecipeEditingError.self) { try draft.makeSnapshot() }
    draft.setValue(.film(.provia), for: .film)
    #expect(!draft.canSave)
    draft.setValue(.integer(10), for: .highlight)
    #expect(draft.canSave)
    let saved = try draft.makeSnapshot()
    #expect(saved.targetCamera == .xe3 && saved.cameraContext == phone.snapshot.cameraContext)
    #expect(saved.copiedFromRecipeID == phone.id)
    #expect(PhoneRecipeDraft(recipe: .init(id: phone.id, snapshot: saved)).camera == .xe3)
  }

  @Test func choicesContainOnlyAvailableValuesWithoutChangingSelections() throws {
    var draft = PhoneRecipeDraft(recipe: try ProductionProfileFixture().bank.copiedToPhone())
    draft.setValue(.film(.realaAce), for: .film)
    draft.setValue(.integer(15), for: .highlight)
    draft.camera = .xe3
    #expect(!draft.choices(for: .film).contains { $0.value == .film(.realaAce) })
    #expect(draft.choices(for: .film).contains { $0.value == .film(.provia) })
    #expect(!draft.isChoiceAvailable(.film(.realaAce), for: .film))
    #expect(draft.isChoiceAvailable(.film(.provia), for: .film))
    #expect(!draft.choices(for: .highlight).contains { $0.value == .integer(15) })
    #expect(draft.choices(for: .highlight).contains { $0.value == .integer(10) })
    #expect(!draft.isChoiceAvailable(.integer(15), for: .highlight))
    #expect(!draft.isAvailable(.colorChrome))
    #expect(draft.choices(for: .colorChrome).isEmpty)
    #expect(draft.value(for: .film) == .film(.realaAce))
    #expect(draft.value(for: .highlight) == .integer(15))
    #expect(!draft.canSave)
    draft.camera = .xt5
    #expect(draft.choices(for: .film).contains { $0.value == .film(.realaAce) })
    #expect(draft.choices(for: .highlight).contains { $0.value == .integer(15) })
    #expect(draft.canSave)
  }

  @Test func unavailableFieldsAndDormantGrainSizeSurviveSaveReopenAndSwitchBack() throws {
    let original = try ProductionProfileFixture().bank.copiedToPhone()
    var draft = PhoneRecipeDraft(recipe: original)
    draft.setGrainSize(.large)
    draft.setValue(.effect(.strong), for: .colorChrome)
    draft.camera = .xe3
    #expect(draft.canSave)
    let saved = try draft.makeSnapshot()
    var reopened = PhoneRecipeDraft(recipe: .init(id: original.id, snapshot: saved))
    #expect(reopened.grain?.size == .large)
    #expect(!reopened.isAvailable(.grainSize))
    reopened.camera = .xt5
    #expect(reopened.value(for: .colorChrome) == .effect(.strong))
    #expect(reopened.grain?.size == .large)
    reopened.setGrainEffect(.off)
    #expect(!reopened.isAvailable(.grainSize))
    let off = try reopened.makeSnapshot()
    var offDraft = PhoneRecipeDraft(recipe: .init(id: original.id, snapshot: off))
    offDraft.setGrainEffect(.strong)
    #expect(offDraft.grain?.size == .large)
  }

  @Test func cameraSupportedButUnimplementedConversionValuesCanBeSaved() throws {
    var draft = PhoneRecipeDraft(recipe: try ProductionProfileFixture().bank.copiedToPhone())
    draft.setValue(.integer(0), for: .dynamicRange)
    draft.setValue(.whiteBalance(.daylight), for: .whiteBalance)
    draft.setGrainEffect(.weak)
    #expect(draft.canSave)
    let saved = try draft.makeSnapshot()
    #expect(!RecipeCodecRegistry().assess(saved).issues.isEmpty)
    #expect(saved.standardRecipe.value(for: .dynamicRange) == .integer(0))
  }

  @Test func unknownImportedAvailableValueBlocksRenameUntilRepaired() throws {
    let f = try ProductionProfileFixture()
    var raw = f.properties
    raw[0xD192] = 99
    let original = try f.bank(raw).copiedToPhone()
    var draft = PhoneRecipeDraft(recipe: original)
    draft.name = "Repair"
    #expect(!draft.canSave)
    draft.setValue(.film(.provia), for: .film)
    #expect(draft.canSave)
    #expect(try draft.makeSnapshot().standardRecipe.value(for: .film) == .film(.provia))
    #expect(original.snapshot.importedSettings == (try f.bank(raw)).importedSettings)
  }

  @Test func temperatureUsesCameraDomainOnlyWhenActive() throws {
    var draft = PhoneRecipeDraft(recipe: try ProductionProfileFixture().bank.copiedToPhone())
    draft.temperature = "not a number"
    #expect(draft.canSave)
    draft.setValue(.whiteBalance(.temperature), for: .whiteBalance)
    #expect(!draft.canSave)
    draft.temperature = "5310"
    #expect(draft.canSave)
    draft.camera = .xe3
    #expect(!draft.canSave)
    #expect(draft.value(for: .kelvin) == .integer(5310))
    #expect(!draft.choices(for: .kelvin).contains { $0.value == .integer(5310) })
    #expect(draft.choices(for: .kelvin).contains { $0.value == .integer(5300) })
    draft.temperature = "5300"
    #expect(draft.canSave)
    draft.temperature = "5301"
    #expect(!draft.canSave)
    draft.camera = .xt5
    #expect(!draft.canSave)
  }

  @Test func monochromeControlsFollowFilmAndRetainSavedValues() throws {
    let phone = try ProductionProfileFixture().bank.copiedToPhone()
    var draft = PhoneRecipeDraft(recipe: phone)
    draft.setValue(.integer(50), for: .monochromeWarmCool)
    #expect(!draft.isAvailable(.monochromeWarmCool))
    #expect(draft.choices(for: .monochromeWarmCool).isEmpty)
    draft.setValue(.film(.acros), for: .film)
    #expect(draft.isAvailable(.monochromeWarmCool))
    #expect(draft.choices(for: .monochromeWarmCool).contains { $0.value == .integer(50) })
    draft.setValue(.film(.provia), for: .film)
    #expect(!draft.isAvailable(.monochromeWarmCool))
    let saved = try draft.makeSnapshot()
    var reopened = PhoneRecipeDraft(recipe: .init(id: phone.id, snapshot: saved))
    reopened.setValue(.film(.monochrome), for: .film)
    #expect(reopened.value(for: .monochromeWarmCool) == .integer(50))
  }

  @Test func emptyNameAndUnsupportedNumericStepCannotSave() throws {
    var draft = PhoneRecipeDraft(recipe: try ProductionProfileFixture().bank.copiedToPhone())
    draft.name = " \n "
    #expect(!draft.canSave)
    #expect(throws: PhoneRecipeEditingError.emptyName) { try draft.makeSnapshot() }
    draft.name = "Test"
    draft.setValue(.integer(300), for: .dynamicRange)
    #expect(!draft.canSave)
    draft.setValue(.integer(200), for: .dynamicRange)
    #expect(draft.canSave)
  }

  @Test func unchangedDraftPreservesSnapshotAndRenamingOnlyKeepsCanonicalDigest() throws {
    let phone = try ProductionProfileFixture().bank.copiedToPhone()
    var draft = PhoneRecipeDraft(recipe: phone)
    #expect(!draft.hasChanges)
    #expect(try draft.makeSnapshot() == phone.snapshot)
    draft.name = "  Renamed  "
    let saved = try draft.makeSnapshot()
    #expect(saved.name == "Renamed" && saved.id != phone.snapshot.id)
    #expect(saved.settingsDigest == phone.snapshot.settingsDigest)
    #expect(saved.standardRecipe == phone.snapshot.standardRecipe)
  }
}
