import Foundation

/// Conservative identity for this live connection; never a fabricated stable camera serial.
public struct RecipeCameraContext: Sendable, Equatable, Codable {
  public let model: String
  public let firmware: String
  public let capability: String
  public let sessionIdentity: UUID
  public let sessionGeneration: UInt64
  public init(
    model: String, firmware: String, capability: String, sessionIdentity: UUID,
    sessionGeneration: UInt64
  ) {
    self.model = model
    self.firmware = firmware
    self.capability = capability
    self.sessionIdentity = sessionIdentity
    self.sessionGeneration = sessionGeneration
  }

}

public struct ImportedRecipeProperty: Sendable, Equatable, Codable {
  public let code: UInt16
  public let raw: Data
  public init(code: UInt16, raw: Data) {
    self.code = code
    self.raw = raw
  }

}

public enum RecipeRenderingIssue: Sendable, Equatable, Codable {
  case unsupportedMeasuredDomain, unsupportedCameraContext
  case unvalidatedDependency(String)
  case conversionProfileUnvalidated
  case unmappedProperty(UInt16)
  case unsupportedValue(UInt16)
}

public enum RecipeImportError: Error, Sendable, Equatable {
  case invalidSlot, incompletePropertyBlock
  case malformedProperty(UInt16)
  case unsupportedRendering([RecipeRenderingIssue])
}

/// Immutable lossless import with current finite support assessed from its preserved raw values.
/// Requested settings remain independent of source-specific effective conversion adjustments.
public struct RecipeSnapshot: Sendable, Equatable, Codable, Identifiable {
  public let id: UUID
  public let slot: Int
  public let name: String
  public let importedName: Data
  public let importedSettings: [ImportedRecipeProperty]
  /// Canonical lossless settings digest, including unmapped fields; excludes name/slot/time/ID.
  public let settingsDigest: String
  public let sourceSettingsDigest: String
  public let standardRecipe: StandardRecipe
  public var targetCamera: RecipeCameraModel { standardRecipe.camera }
  /// Exposed by the camera menu, but not present in the currently decoded native bank data.
  public var unreadImportedSettings: [RecipeSettingID] {
    cameraContext.model == "X-T5" ? [.rawRecording, .outputFormat] : [.iso]
  }
  public let cameraContext: RecipeCameraContext
  public let importedAt: Date
  /// Recorded import observations. Frozen older observations are not an executable support cache.
  public let renderingIssues: [RecipeRenderingIssue]
  /// Phone copies retain the original camera slot as provenance, never as selection identity.
  public let copiedFromRecipeID: UUID?
  public var isPhoneRecipe: Bool { copiedFromRecipeID != nil }
  public var displayLabel: String { isPhoneRecipe ? "Phone recipe \(name)" : "C\(slot) \(name)" }

  public init(
    id: UUID, slot: Int, name: String, importedName: Data,
    importedSettings: [ImportedRecipeProperty],
    settingsDigest: String, cameraContext: RecipeCameraContext, importedAt: Date,
    renderingIssues: [RecipeRenderingIssue], copiedFromRecipeID: UUID? = nil,
    standardRecipe: StandardRecipe? = nil
  ) {
    self.id = id
    self.slot = slot
    self.name = name
    self.importedName = importedName
    self.importedSettings = importedSettings
    self.sourceSettingsDigest = settingsDigest
    let standard = standardRecipe ?? StandardRecipeImport.decode(model: cameraContext.model, properties: importedSettings)
    self.standardRecipe = standard
    var canonical = Data("fuji.standard-recipe.v1\0\(standard.camera.rawValue)\0".utf8)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    for id in RecipeSettingID.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
      canonical.append(contentsOf: id.rawValue.utf8); canonical.append(0)
      canonical.append(try! encoder.encode(standard.value(for: id)))
    }
    self.settingsDigest = ResourceChecksum.sha256(canonical)
    self.cameraContext = cameraContext
    self.importedAt = importedAt
    self.renderingIssues = renderingIssues
    self.copiedFromRecipeID = copiedFromRecipeID
  }

  public func copiedToPhone() -> PhoneRecipe {
    let snapshot = RecipeSnapshot(
      id: UUID(), slot: slot, name: name, importedName: importedName,
      importedSettings: importedSettings, settingsDigest: sourceSettingsDigest,
      cameraContext: cameraContext,
      importedAt: importedAt, renderingIssues: renderingIssues, copiedFromRecipeID: id,
      standardRecipe: standardRecipe)
    return PhoneRecipe(id: id, snapshot: snapshot)
  }

  public func replacingStandardRecipe(_ recipe: StandardRecipe, name: String) -> RecipeSnapshot {
    RecipeSnapshot(id: UUID(), slot: slot, name: name, importedName: importedName,
      importedSettings: importedSettings, settingsDigest: sourceSettingsDigest,
      cameraContext: cameraContext, importedAt: importedAt, renderingIssues: renderingIssues,
      copiedFromRecipeID: copiedFromRecipeID, standardRecipe: recipe)
  }

  public func settings(using codecs: RecipeCodecRegistry) throws -> RecipeSettings {
    try codecs.requireSettings(self)
  }
  public func renderingSupport(using codecs: RecipeCodecRegistry) -> RecipeRenderingSupport {
    codecs.assess(self).renderingSupport
  }
  public func requireRenderable(using codecs: RecipeCodecRegistry) throws {
    _ = try codecs.requireSettings(self)
  }

}

public enum RecipeRenderingSupport: Sendable, Equatable {
  case supported(RecipeSettings)
  case unsupported([RecipeRenderingIssue])
}
