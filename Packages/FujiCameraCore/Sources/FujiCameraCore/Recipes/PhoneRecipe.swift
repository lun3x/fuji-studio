import Foundation

/// Stable chooser identity points to the current immutable rendering snapshot.
public struct PhoneRecipe: Sendable, Equatable, Identifiable {
  public let id: UUID
  public let snapshot: RecipeSnapshot
  public init(id: UUID, snapshot: RecipeSnapshot) {
    self.id = id
    self.snapshot = snapshot
  }

}
