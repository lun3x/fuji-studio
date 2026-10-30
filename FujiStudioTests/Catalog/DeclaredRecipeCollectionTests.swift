import Foundation
import Testing

@testable import FujiCameraCore
@testable import FujiStudio

struct DeclaredRecipeCollectionTests {
  @Test func mixedModelOfflineEditPreservesUnknownBytesAndFrozenJob() async throws {
    let f = try RenderFixture()
    defer { f.remove() }
    let url = f.root.appendingPathComponent("mixed.store")
    let catalog = try SwiftDataCatalog(storeURL: url)
    let xt5 = try await catalog.copyRecipeToPhone(f.recipe)
    let original = try await catalog.copyRecipeToPhone(fixtureXE3Recipe(unknown: true))
    let job = ExportJob(
      id: UUID(), submittedAt: Date(), recipeSnapshot: original.snapshot,
      items: [ExportItem(source: f.source, operationID: UUID(), state: .queued)], state: .queued)
    try await catalog.saveJob(job)
    var draft = PhoneRecipeDraft(recipe: original)
    draft.name = "Offline XE3"
    draft.setValue(.option(.auto1), for: .iso)
    let edited = try await catalog.updatePhoneRecipe(draft)
    #expect(edited.id == original.id && edited.snapshot.id != original.snapshot.id)
    #expect(edited.snapshot.importedSettings.first { $0.code == 99 }?.raw == Data([0xaa, 0xbb]))
    let reopened = try SwiftDataCatalog(storeURL: url)
    #expect(try await reopened.phoneRecipes() == [xt5, edited])
    #expect(try await reopened.job(id: job.id).recipeSnapshot == original.snapshot)
  }
  @Test func declaredThreeSlotCollectionReopens() async throws {
    let f = try RenderFixture()
    defer { f.remove() }
    let url = f.root.appendingPathComponent("three.store")
    let catalog = try SwiftDataCatalog(storeURL: url)
    let recipes = (1...3).map { slot in remap(f.recipe, slot: slot) }
    let slots = (1...3).map { RecipeSlot(id: $0, label: "Bank \($0)") }
    try await catalog.replaceRecipes(fixtureCollection(recipes, slots: slots))
    let reopened = try SwiftDataCatalog(storeURL: url)
    #expect(try await reopened.latestRecipeSlots().map(\.id) == [1, 2, 3])
    #expect(try await reopened.latestRecipes() == recipes)
  }
  @Test func partialCollectionRetainsPreviousCompleteImport() async throws {
    let f = try RenderFixture()
    defer { f.remove() }
    let catalog = try SwiftDataCatalog(storeURL: f.root.appendingPathComponent("partial.store"))
    let recipes = (1...3).map { remap(f.recipe, slot: $0) }
    let slots = (1...3).map { RecipeSlot(id: $0, label: "C\($0)") }
    try await catalog.replaceRecipes(fixtureCollection(recipes, slots: slots))
    await #expect(throws: CatalogError.invalidRecipeCollection) {
      try await catalog.replaceRecipes(fixtureCollection(Array(recipes.dropLast()), slots: slots))
    }
    #expect(try await catalog.latestRecipes() == recipes)
    #expect(try await catalog.latestRecipeSlots() == slots)
  }
  @Test func declaredNoBanksIsACompleteEmptyCollection() async throws {
    let f = try RenderFixture()
    defer { f.remove() }
    let url = f.root.appendingPathComponent("empty.store")
    let catalog = try SwiftDataCatalog(storeURL: url)
    try await catalog.replaceRecipes(fixtureCollection([], slots: []))
    let reopened = try SwiftDataCatalog(storeURL: url)
    #expect(try await reopened.latestRecipes().isEmpty)
    #expect(try await reopened.latestRecipeSlots().isEmpty)
  }
  private func remap(_ r: RecipeSnapshot, slot: Int) -> RecipeSnapshot {
    .init(
      id: UUID(), slot: slot, name: r.name, importedName: r.importedName,
      importedSettings: r.importedSettings, settingsDigest: r.sourceSettingsDigest,
      cameraContext: r.cameraContext, importedAt: r.importedAt, renderingIssues: r.renderingIssues)
  }
}
