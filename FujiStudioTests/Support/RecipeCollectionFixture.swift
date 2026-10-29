import Foundation
import FujiCameraCore

func fixtureXE3Recipe(unknown: Bool = false) throws -> RecipeSnapshot {
  var p: [UInt16: Data] = [
    1: Data([13]), 2: Data([3]), 3: Data([1]), 4: Data([8]), 5: Data([13]), 6: Data([11]),
    7: Data([6]), 8: Data([5]), 9: Data([2]), 10: Data([7]), 11: Data([4]), 12: Data([0]),
    13: Data([0xb9, 1]),
  ]
  if unknown { p[99] = Data([0xaa, 0xbb]) }
  return try XE3RecipeCodec.recipe(
    slot: 4, nameData: Data("XE3 fixture\0".utf8), properties: p,
    context: .init(
      model: "X-E3", firmware: "1.30", capability: XE3Support.identifier, sessionIdentity: UUID(),
      sessionGeneration: 1), importedAt: Date(timeIntervalSince1970: 0))
}

func fixtureCollection(
  _ recipes: [RecipeSnapshot], slots: [RecipeSlot]? = nil, context: CameraExecutionContext? = nil
) -> ImportedRecipeCollection {
  let recipeContext = recipes.first?.cameraContext
  let camera =
    context
    ?? CameraExecutionContext(
      model: recipeContext?.model ?? "X-T5", firmware: recipeContext?.firmware ?? "4.31",
      capability: recipeContext?.capability ?? "X-T5_0200",
      supportVersion: recipeContext?.model == "X-E3"
        ? XE3Support.identifier : XT5WorkingProfile.supportVersion,
      sessionIdentity: recipeContext?.sessionIdentity ?? UUID(),
      generation: recipeContext?.sessionGeneration ?? 1)
  let lookup=recipeContext ?? context.map { RecipeCameraContext(model:$0.model,firmware:$0.firmware,capability:$0.capability,sessionIdentity:$0.sessionIdentity,sessionGeneration:$0.generation) }
  let baseline =
    lookup.flatMap { try? RecipeCodecRegistry().capabilities(for: $0) }
    ?? RecipeCodecRegistry.xt5Capabilities
  let capabilities = CameraCapabilities(
    bankSlots: slots ?? baseline.bankSlots, settings: baseline.settings,
    recipeImport: baseline.recipeImport, sourceConstraints: baseline.sourceConstraints)
  let support = VerifiedCameraSupport(
    adapterID: .init(rawValue: camera.model == "X-E3" ? "fujifilm.xe3" : "fujifilm.xt5"),
    model: camera.model, firmware: camera.firmware, capability: camera.capability,
    capabilityOrigin: .applicationDefined, supportVersion: camera.supportVersion,
    capabilities: capabilities)
  return .init(
    recipes: recipes, declaredSlots: capabilities.bankSlots, context: camera, support: support)
}
