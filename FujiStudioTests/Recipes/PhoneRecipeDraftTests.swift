@testable import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

struct PhoneRecipeDraftTests {
    @Test func grainControlsPreserveEachOtherAndRememberSizeWhileOff() throws {
        let original = try ProductionProfileFixture().bank.copiedToPhone()
        var draft = PhoneRecipeDraft(recipe: original)
        #expect(draft.grain == PhoneRecipeGrain(effect: .strong, size: .small))
        draft.setGrainSize(.large); #expect(draft.value(for: .grain) == 5)
        draft.setGrainEffect(.weak); #expect(draft.value(for: .grain) == 4)
        draft.setGrainEffect(.off); #expect(draft.value(for: .grain) == 7)
        draft.setGrainSize(.small); #expect(draft.value(for: .grain) == 7)
        let saved = PhoneRecipe(id: original.id, snapshot: try draft.makeSnapshot())
        var reopened = PhoneRecipeDraft(recipe: saved)
        #expect(reopened.grain == PhoneRecipeGrain(effect: .off, size: .large))
        reopened.setGrainEffect(.strong); #expect(reopened.value(for: .grain) == 5)
        reopened.setGrainSize(.small); #expect(reopened.value(for: .grain) == 3)
    }

    @Test(arguments: [UInt16(1), 99])
    func legacyAndUnknownGrainStayUnchangedUntilExplicitlyEdited(_ raw: UInt16) throws {
        let f = try ProductionProfileFixture()
        var properties = f.properties; properties[0xD195] = raw
        let original = try f.bank(properties).copiedToPhone()
        var draft = PhoneRecipeDraft(recipe: original)
        #expect(try draft.makeSnapshot() == original.snapshot)
        draft.setGrainSize(.large)
        if raw == 1 { draft.setGrainEffect(.off) }
        #expect(!draft.hasChanges)
        #expect(try draft.makeSnapshot() == original.snapshot)
        draft.setGrainEffect(.weak)
        #expect(draft.value(for: .grain) == 2)
        #expect(try draft.makeSnapshot().importedSettings.first { $0.code == 0xD195 }?.raw == ProtocolProbeFixtures.word(2))
    }

    @Test(arguments: [UInt16(2), 3, 4, 5, 6, 7])
    func allGrainCombinationsCanBeSavedWithoutChangingOtherSettings(_ raw: UInt16) throws {
        let original = try ProductionProfileFixture().bank.copiedToPhone()
        var draft = PhoneRecipeDraft(recipe: original)
        draft.setValue(raw, for: .grain)
        let snapshot = try draft.makeSnapshot()
        #expect(PhoneRecipeDraft(recipe: PhoneRecipe(id: original.id, snapshot: snapshot)).value(for: .grain) == raw)
        #expect(snapshot.importedSettings.filter { $0.code != 0xD195 } == original.snapshot.importedSettings.filter { $0.code != 0xD195 })
        if [2, 4, 5].contains(raw) {
            #expect(throws: RecipeImportError.self) { try snapshot.requireRenderable(using: RecipeCodecRegistry()) }
        } else { try snapshot.requireRenderable(using: RecipeCodecRegistry()) }
    }

    @Test func untouchedPaddedNameDoesNotCreateARevision() throws {
        let source = try ProductionProfileFixture().bank
        let camera = try XT5RecipeCodec.recipe(slot: source.slot,
            nameData: ProtocolProbeFixtures.string("  My look  "),
            properties: Dictionary(uniqueKeysWithValues: source.importedSettings.map { ($0.code, $0.raw) }),
            context: source.cameraContext, importedAt: source.importedAt)
        let original = camera.copiedToPhone()
        let draft = PhoneRecipeDraft(recipe: original)
        #expect(!draft.hasChanges)
        #expect(try draft.makeSnapshot() == original.snapshot)
        var changed = draft; changed.setValue(1, for: .film)
        #expect(try changed.makeSnapshot().name == original.snapshot.name)
    }

    @Test func changedSettingsProduceValidSnapshotAndPreserveUntouchedValues() throws {
        let original = try ProductionProfileFixture().bank.copiedToPhone()
        var draft = PhoneRecipeDraft(recipe: original)
        draft.name = "  My daylight 🌤  "
        draft.setValue(1, for: .film)
        draft.setValue(UInt16(bitPattern: Int16(-5)), for: .highlight)
        draft.setValue(0x6000, for: .noiseReduction)
        draft.setValue(32775, for: .whiteBalance)
        draft.temperature = "5200"
        let updated = try draft.makeSnapshot()
        #expect(updated.id != original.snapshot.id)
        #expect(updated.name == "My daylight 🌤")
        #expect(updated.copiedFromRecipeID == original.id)
        #expect(updated.settingsDigest != original.snapshot.settingsDigest)
        let settings = try updated.settings(using: RecipeCodecRegistry())
        #expect(settings.film == .provia)
        #expect(settings.highlightTenths == -5)
        #expect(settings.noiseReduction == 3)
        #expect(settings.whiteBalance == .temperature)
        #expect(settings.kelvin == 5200)
        let changed: Set<UInt16> = [0xD192, 0xD19D, 0xD1A1, 0xD199, 0xD19C]
        #expect(updated.importedSettings.filter { !changed.contains($0.code) } == original.snapshot.importedSettings.filter { !changed.contains($0.code) })
        #expect(updated.importedName == original.snapshot.importedName)
        #expect(updated.cameraContext == original.snapshot.cameraContext)
    }

    @Test func renamingUnsupportedRecipePreservesAllSettingsWithoutCoercion() throws {
        let f = try ProductionProfileFixture()
        var raw = f.properties; raw[0xD192] = 99; raw[0xD1A4] = 2
        let original = try f.bank(raw).copiedToPhone()
        var draft = PhoneRecipeDraft(recipe: original)
        #expect(draft.value(for: .film) == 99)
        draft.name = "Renamed unsupported"
        let updated = try draft.makeSnapshot()
        #expect(updated.importedSettings == original.snapshot.importedSettings)
        #expect(updated.settingsDigest == original.snapshot.settingsDigest)
        #expect(updated.renderingSupport(using: RecipeCodecRegistry()) == original.snapshot.renderingSupport(using: RecipeCodecRegistry()))
        #expect(updated.name == "Renamed unsupported")
        #expect(try PhoneRecipeDraft(recipe: original).makeSnapshot() == original.snapshot)
    }

    @Test func invalidNewValuesAreRejectedWithoutChangingTheOriginal() throws {
        let original = try ProductionProfileFixture().bank.copiedToPhone()
        var empty = PhoneRecipeDraft(recipe: original); empty.name = " \n "
        #expect(throws: PhoneRecipeEditingError.emptyName) { try empty.makeSnapshot() }
        for value in ["", "abc", "2499", "10001"] {
            var draft = PhoneRecipeDraft(recipe: original); draft.temperature = value
            #expect(throws: PhoneRecipeEditingError.invalidTemperature) { try draft.makeSnapshot() }
        }
        var invalid = PhoneRecipeDraft(recipe: original); invalid.setValue(200, for: .dynamicRange)
        #expect(throws: PhoneRecipeEditingError.self) { try invalid.makeSnapshot() }
        for raw: UInt16 in [0, 8, 99] {
            var draft = PhoneRecipeDraft(recipe: original); draft.setValue(raw, for: .grain)
            #expect(throws: PhoneRecipeEditingError.self) { try draft.makeSnapshot() }
        }
        #expect(try original.snapshot.settings(using: RecipeCodecRegistry()).dynamicRange == 400)
    }

    @Test(arguments: PhoneRecipeSetting.allCases.filter { $0 != .kelvin && $0 != .grain })
    func offeredSettingsRemainInsideRendererSupport(_ setting: PhoneRecipeSetting) throws {
        let original = try ProductionProfileFixture().bank.copiedToPhone()
        for choice in setting.choices {
            var draft = PhoneRecipeDraft(recipe: original)
            draft.setValue(choice.value, for: setting)
            try draft.makeSnapshot().requireRenderable(using: RecipeCodecRegistry())
        }
    }
}
