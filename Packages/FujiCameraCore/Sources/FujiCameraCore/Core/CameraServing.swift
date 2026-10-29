import Foundation

public protocol CameraServing: Sendable {
  func support(for context: CameraExecutionContext) async throws -> VerifiedCameraSupport
  func executionContext() async throws -> CameraExecutionContext
  func states() async -> AsyncStream<CameraState>
  func connect() async throws
  func importRecipes() async throws -> ImportedRecipeCollection
  func render(raw: PreparedRAW, recipe: RecipeSnapshot, policy: OutputPolicy) async throws
    -> CameraJPEG
  func disconnect() async
  func resetConnection() async throws
}

public enum CameraServiceError: Error, Sendable, Equatable {
  case unsupportedSource, unsupportedSettings, unsupportedProfile, unsupportedContext
  case sourceChanged, notReady, cancelled, storage, invalidOutput, profileReadbackMismatch
  case invalidMetadata(String)
  case preexistingObjects, ownershipChanged, timeout
  case uncertainOperation(UUID)
  case closeUnconfirmed
  case recipeImportUnavailable
  case recipeImportFailed(restorationConfirmed: Bool)
  case transport(PTPError)
}

/// Session affinity is explicit; model/firmware are compatibility, never physical identity.
public struct CameraExecutionContext: Sendable, Codable, Hashable {
  public let model: String, firmware: String, capability: String, supportVersion: String
  public let sessionIdentity: UUID
  public let generation: UInt64
  public init(
    model: String, firmware: String, capability: String, supportVersion: String,
    sessionIdentity: UUID, generation: UInt64
  ) {
    self.model = model
    self.firmware = firmware
    self.capability = capability
    self.supportVersion = supportVersion
    self.sessionIdentity = sessionIdentity
    self.generation = generation
  }

}
