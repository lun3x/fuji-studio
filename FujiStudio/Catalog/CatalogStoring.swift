import Foundation

protocol CatalogStoring: Sendable {
    func upsertSources(_ sources: [PhotoSource]) async throws
    func replaceRecipes(_ snapshots: [RecipeSnapshot]) async throws
    func recipes(camera: CameraExecutionContext) async throws -> [RecipeSnapshot]
    func latestRecipes() async throws -> [RecipeSnapshot]
    func phoneRecipes() async throws -> [RecipeSnapshot]
    func copyRecipeToPhone(_ recipe: RecipeSnapshot) async throws -> RecipeSnapshot
    func versions(sourceID: SourceID) async throws -> [SavedVersion]
    func saveJob(_ job: ExportJob) async throws
    func job(id: UUID) async throws -> ExportJob
    func unfinishedJobs() async throws -> [ExportJob]
    func confirmSaved(jobID: UUID, operationID: UUID, version: SavedVersion) async throws
    func setAvailability(assetID: String, availability: AssetAvailability) async throws
}

enum CatalogError: Error, Sendable, Equatable {
    case durableFailure(String)
    case missingJob(UUID)
    case invalidState(String)
    case invalidRecipeCollection
    case conflictingSnapshot(UUID)
    case conflictingOperation(UUID)
}
