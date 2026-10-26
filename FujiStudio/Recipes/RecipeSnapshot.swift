import Foundation

/// Conservative identity for this live connection; never a fabricated stable camera serial.
struct RecipeCameraContext: Sendable, Equatable, Codable {
    let model: String
    let firmware: String
    let capability: String
    let sessionIdentity: UUID
    let sessionGeneration: UInt64
}

struct ImportedRecipeProperty: Sendable, Equatable, Codable {
    let code: UInt16
    let raw: Data
}

enum RecipeRenderingIssue: Sendable, Equatable, Codable {
    case conversionProfileUnvalidated
    case unmappedProperty(UInt16)
    case unsupportedValue(UInt16)
}

enum RecipeImportError: Error, Sendable, Equatable {
    case invalidSlot, incompletePropertyBlock, malformedProperty(UInt16)
    case unsupportedRendering([RecipeRenderingIssue])
}

/// Import snapshot only. Normalized conversion settings must not be invented before the actual
/// per-RAF profile schema is established. Every imported byte remains available for that work.
struct RecipeSnapshot: Sendable, Equatable, Codable, Identifiable {
    let id: UUID
    let slot: Int
    let name: String
    let importedName: Data
    let importedSettings: [ImportedRecipeProperty]
    /// Canonical lossless settings digest, including unmapped fields; excludes name/slot/time/ID.
    let settingsDigest: String
    let cameraContext: RecipeCameraContext
    let importedAt: Date
    let renderingIssues: [RecipeRenderingIssue]

    func requireRenderable() throws {
        guard renderingIssues.isEmpty else { throw RecipeImportError.unsupportedRendering(renderingIssues) }
    }
}
