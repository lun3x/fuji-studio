import Foundation

/// Stable chooser identity points to the current immutable rendering snapshot.
struct PhoneRecipe: Sendable, Equatable, Identifiable {
    let id: UUID
    let snapshot: RecipeSnapshot
}
