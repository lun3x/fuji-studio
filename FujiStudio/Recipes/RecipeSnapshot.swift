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
    /// Phone copies retain the original camera slot as provenance, never as selection identity.
    let copiedFromRecipeID: UUID?
    var isPhoneRecipe: Bool { copiedFromRecipeID != nil }
    var displayLabel: String { isPhoneRecipe ? "Phone recipe \(name)" : "C\(slot) \(name)" }

    init(id: UUID, slot: Int, name: String, importedName: Data, importedSettings: [ImportedRecipeProperty],
         settingsDigest: String, cameraContext: RecipeCameraContext, importedAt: Date,
         renderingIssues: [RecipeRenderingIssue], copiedFromRecipeID: UUID? = nil) {
        self.id = id; self.slot = slot; self.name = name; self.importedName = importedName
        self.importedSettings = importedSettings; self.settingsDigest = settingsDigest
        self.cameraContext = cameraContext; self.importedAt = importedAt
        self.renderingIssues = renderingIssues; self.copiedFromRecipeID = copiedFromRecipeID
    }

    func copiedToPhone() -> PhoneRecipe {
        let snapshot = RecipeSnapshot(id: UUID(), slot: slot, name: name, importedName: importedName,
            importedSettings: importedSettings, settingsDigest: settingsDigest, cameraContext: cameraContext,
            importedAt: importedAt, renderingIssues: renderingIssues, copiedFromRecipeID: id)
        return PhoneRecipe(id: id, snapshot: snapshot)
    }

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
