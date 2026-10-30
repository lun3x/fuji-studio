import Foundation
import Testing

@testable import FujiCameraCore
@testable import FujiStudio

struct ModelAwareWorkspaceTests {
  @Test func receiptAdoptsDeclaredSlotsAndFinalContextTogether() throws {
    let r = try fixtureXE3Recipe()
    let recipes = (1...3).map { slot in
      RecipeSnapshot(
        id: UUID(), slot: slot, name: r.name, importedName: r.importedName,
        importedSettings: r.importedSettings, settingsDigest: r.sourceSettingsDigest,
        cameraContext: r.cameraContext, importedAt: r.importedAt, renderingIssues: [])
    }
    let receipt = fixtureCollection(recipes, slots: (1...3).map { .init(id: $0, label: "C\($0)") })
    var state = WorkspaceState()
    state.reduce(.recipesImported(receipt))
    #expect(state.currentCameraExecutionContext == receipt.context)
    #expect(state.recipeSlots == receipt.declaredSlots)
    #expect(state.recipes == recipes)
    #expect(state.cameraSupport == receipt.support)
  }
  @Test func otherModelPhoneRecipeRemainsEditable() throws {
    let xe3 = try fixtureXE3Recipe()
    let xt5 = try ProductionProfileFixture().bank
    let phone = xt5.copiedToPhone()
    let receipt = fixtureCollection([xe3], slots: [.init(id: 4, label: "C4")])
    var state = WorkspaceState()
    state.reduce(.recipesImported(receipt))
    state.reduce(.phoneRecipesLoaded([phone]))
    #expect(state.phoneRecipes == [phone])
    #expect(state.recipeExecutionReason(phone.snapshot) != nil)
    #expect(PhoneRecipeDraft(recipe: phone).supportsSettingsEditing)
  }
  @Test func modelSwitchCannotUseKnownOtherModelSource() throws {
    let f = try RenderFixture()
    defer { f.remove() }
    var source = f.source
    source.compatibility = .supported(model: "X-E3")
    let recipe = f.recipe
    let recipes = (1...7).map { slot in
      RecipeSnapshot(
        id: UUID(), slot: slot, name: recipe.name, importedName: recipe.importedName,
        importedSettings: recipe.importedSettings, settingsDigest: recipe.sourceSettingsDigest,
        cameraContext: recipe.cameraContext, importedAt: recipe.importedAt, renderingIssues: [])
    }
    let receipt = fixtureCollection(recipes)
    var state = WorkspaceState(sources: [source], access: .full)
    state.reduce(.recipesImported(receipt))
    let session = CameraSession(
      generation: receipt.context.generation,
      connection: .init(name: "X-T5", usbVendorID: 1, usbProductID: 2))
    state.reduce(.cameraChanged(.ready(session), context: receipt.context))
    state.reduce(.sourceTapped(source.id))
    let effects = state.reduce(.recipeSelected(slot: 1))
    #expect(effects.isEmpty)
    #expect(state.selectedRecipe == nil)
    #expect(state.recipeExecutionReason(recipes[0]) != nil)
    #expect(!state.canExport)

    let xe3 = try fixtureXE3Recipe()
    let xe3Receipt = fixtureCollection([xe3], slots: [.init(id: xe3.slot, label: "C\(xe3.slot)")])
    state.reduce(.recipesImported(xe3Receipt))
    state.reduce(.cameraChanged(.ready(session), context: xe3Receipt.context))
    #expect(state.recipeExecutionReason(xe3) == nil)
    #expect(!state.reduce(.recipeSelected(slot: xe3.slot)).isEmpty)
    #expect(state.selectedRecipe == xe3)
    #expect(state.canExport)
  }
}
