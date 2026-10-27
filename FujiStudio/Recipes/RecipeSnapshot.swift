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
    case unsupportedMeasuredDomain, unsupportedCameraContext
    case conversionProfileUnvalidated
    case unmappedProperty(UInt16)
    case unsupportedValue(UInt16)
}

enum RecipeImportError: Error, Sendable, Equatable {
    case invalidSlot, incompletePropertyBlock, malformedProperty(UInt16)
    case unsupportedRendering([RecipeRenderingIssue])
}

/// Immutable lossless import with current finite support assessed from its preserved raw values.
/// Requested settings remain independent of source-specific effective conversion adjustments.
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
    /// Recorded import observations. Frozen older observations are not an executable support cache.
    let renderingIssues: [RecipeRenderingIssue]
    var normalizedSettings: NormalizedRecipeSettings { get throws { try XT5WorkingProfile.normalize(self) } }
    var renderingSupport: RecipeRenderingSupport {
        do { return .supported(try normalizedSettings) }
        catch CameraServiceError.unsupportedContext { return .unsupported([.unsupportedCameraContext]) }
        catch { return .unsupported([.unsupportedMeasuredDomain]) }
    }

    func requireRenderable() throws {
        if case .unsupported(let issues) = renderingSupport { throw RecipeImportError.unsupportedRendering(issues) }
    }
}

enum RecipeRenderingSupport: Sendable, Equatable {
    case supported(NormalizedRecipeSettings)
    case unsupported([RecipeRenderingIssue])
}
