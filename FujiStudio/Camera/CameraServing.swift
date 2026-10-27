import Foundation

protocol CameraServing: Sendable {
    func states() async -> AsyncStream<CameraState>
    func connect() async throws
    func importRecipes() async throws -> [RecipeSnapshot]
    func render(raw: PreparedRAW, recipe: RecipeSnapshot, policy: OutputPolicy) async throws -> CameraJPEG
    func disconnect() async
}

enum CameraServiceError: Error, Sendable, Equatable {
    case unsupportedSource, unsupportedSettings, unsupportedProfile, unsupportedContext
    case sourceChanged, notReady, cancelled, storage, invalidOutput, profileReadbackMismatch
    case preexistingObjects, ownershipChanged, timeout
    case uncertainOperation(UUID), closeUnconfirmed
    case recipeImportFailed(restorationConfirmed: Bool)
    case transport(PTPError)
}

/// Session affinity is explicit; model/firmware are compatibility, never physical identity.
struct CameraExecutionContext: Sendable, Codable, Hashable {
    let model: String, firmware: String, capability: String, supportVersion: String
    let sessionIdentity: UUID
    let generation: UInt64
}
