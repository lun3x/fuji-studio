import Foundation

public enum OutputPolicy: String, Sendable, Codable, Hashable { case fullSizeFineRecordedGeometry }
public enum CameraJPEGQuality: String, Sendable, Codable, Hashable { case fullResolutionFine }

public struct RenderKey: Sendable, Codable, Hashable {
  public let sourceID: SourceID, sourceRevision: String, sourceSHA256: String,
    settingsDigest: String
  public let cameraContext: CameraExecutionContext
  public let width: Int, height: Int, orientation: Int
  public let policy: OutputPolicy
  public let quality: CameraJPEGQuality
  public init(
    sourceID: SourceID, sourceRevision: String, sourceSHA256: String, settingsDigest: String,
    cameraContext: CameraExecutionContext, width: Int, height: Int, orientation: Int,
    policy: OutputPolicy, quality: CameraJPEGQuality
  ) {
    self.sourceID = sourceID
    self.sourceRevision = sourceRevision
    self.sourceSHA256 = sourceSHA256
    self.settingsDigest = settingsDigest
    self.cameraContext = cameraContext
    self.width = width
    self.height = height
    self.orientation = orientation
    self.policy = policy
    self.quality = quality
  }

}

/// Ownership of this single validated file transfers to the caller after confirmed camera cleanup.
/// A completed journal stores provenance, not an additional full-size image copy.
public struct CameraJPEG: Sendable, Codable, Equatable {
  public let fileURL: URL
  public let sourceID: SourceID, sourceRevision: String, sourceSHA256: String
  public let recipeSnapshotID: UUID
  public let settingsDigest: String
  public let cameraContext: CameraExecutionContext
  public let operationID: UUID
  public let width: Int, height: Int, orientation: Int
  public let quality: CameraJPEGQuality
  public let effectiveRecipe: EffectiveRecipeReport
  public let baselineSHA256: String, candidateSHA256: String, outputSHA256: String
  public let key: RenderKey
  public init(
    fileURL: URL, sourceID: SourceID, sourceRevision: String, sourceSHA256: String,
    recipeSnapshotID: UUID, settingsDigest: String, cameraContext: CameraExecutionContext,
    operationID: UUID, width: Int, height: Int, orientation: Int, quality: CameraJPEGQuality,
    effectiveRecipe: EffectiveRecipeReport, baselineSHA256: String, candidateSHA256: String,
    outputSHA256: String, key: RenderKey
  ) {
    self.fileURL = fileURL
    self.sourceID = sourceID
    self.sourceRevision = sourceRevision
    self.sourceSHA256 = sourceSHA256
    self.recipeSnapshotID = recipeSnapshotID
    self.settingsDigest = settingsDigest
    self.cameraContext = cameraContext
    self.operationID = operationID
    self.width = width
    self.height = height
    self.orientation = orientation
    self.quality = quality
    self.effectiveRecipe = effectiveRecipe
    self.baselineSHA256 = baselineSHA256
    self.candidateSHA256 = candidateSHA256
    self.outputSHA256 = outputSHA256
    self.key = key
  }

}

public struct EffectiveRecipeReport: Sendable, Codable, Equatable {
  public let supportVersion: String
  public let requested: RecipeSettings
  public let dormantGrainSizeNotSerialized: Bool
  public let inactiveKelvinPreserved: Bool
  public let lensOptimizerRequested: Bool
  public let lensOptimizerEffective: Bool
  public let lensOptimizerAdjusted: Bool
  public let evidence: String
  public let evidenceBySetting: [RecipeSettingID: SettingEvidence]?
  public let dynamicRangeEffective: Int?
  public var dynamicRangeAdjusted: Bool {
    dynamicRangeEffective.map { $0 != requested.dynamicRange } ?? false
  }
  public init(
    supportVersion: String, requested: RecipeSettings,
    dormantGrainSizeNotSerialized: Bool, inactiveKelvinPreserved: Bool,
    lensOptimizerRequested: Bool, lensOptimizerEffective: Bool, lensOptimizerAdjusted: Bool,
    evidence: String, evidenceBySetting: [RecipeSettingID: SettingEvidence]? = nil,
    dynamicRangeEffective: Int? = nil
  ) {
    self.supportVersion = supportVersion
    self.requested = requested
    self.dormantGrainSizeNotSerialized = dormantGrainSizeNotSerialized
    self.inactiveKelvinPreserved = inactiveKelvinPreserved
    self.lensOptimizerRequested = lensOptimizerRequested
    self.lensOptimizerEffective = lensOptimizerEffective
    self.lensOptimizerAdjusted = lensOptimizerAdjusted
    self.evidence = evidence
    self.evidenceBySetting = evidenceBySetting
    self.dynamicRangeEffective = dynamicRangeEffective
  }

}

extension CameraJPEG {
  /// Relocation preserves the original render's provenance, even for a renamed frozen job recipe.
  public func relocated(to url: URL) -> CameraJPEG {
    CameraJPEG(
      fileURL: url, sourceID: sourceID, sourceRevision: sourceRevision, sourceSHA256: sourceSHA256,
      recipeSnapshotID: recipeSnapshotID, settingsDigest: settingsDigest,
      cameraContext: cameraContext,
      operationID: operationID, width: width, height: height, orientation: orientation,
      quality: quality,
      effectiveRecipe: effectiveRecipe, baselineSHA256: baselineSHA256,
      candidateSHA256: candidateSHA256,
      outputSHA256: outputSHA256, key: key)
  }
}
