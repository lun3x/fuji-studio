import Foundation

public struct RecipeMismatchReport: Codable, Sendable, Equatable {
  public let field: String
  public let requested: String
  public let observed: String
  public var summary: String { "\(field): requested \(requested), observed \(observed)" }
  public init(field: String, requested: String, observed: String) {
    self.field = field
    self.requested = requested
    self.observed = observed
  }

}
public enum RecipeOutputAdmission: Sendable {
  case accepted(EffectiveRecipeReport)
  case rejected(RecipeMismatchReport)
}
public struct CameraOutputAssessment: Sendable {
  public let metadata: ValidatedJPEGMetadata
  public let admission: RecipeOutputAdmission
  public init(metadata: ValidatedJPEGMetadata, admission: RecipeOutputAdmission) {
    self.metadata = metadata
    self.admission = admission
  }

}
