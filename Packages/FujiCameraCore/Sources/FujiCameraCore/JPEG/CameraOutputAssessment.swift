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

extension CameraOutputAssessment {
  public static func assess(
    metadata: ValidatedJPEGMetadata, conversion: PreparedConversion, required: Set<RecipeSettingID>
  ) throws -> CameraOutputAssessment {
    guard let lmo = metadata.lensOptimizer else { throw CameraServiceError.invalidOutput }
    func reject(_ field: String, _ requested: String, _ observed: String) -> CameraOutputAssessment
    {
      .init(
        metadata: metadata,
        admission: .rejected(.init(field: field, requested: requested, observed: observed)))
    }
    if lmo != conversion.expectedLensOptimizer {
      return reject("lensOptimizer", String(conversion.expectedLensOptimizer), String(lmo))
    }
    var evidence: [RecipeSettingID: SettingEvidence] = [.lensOptimizer: .jpegObserved]
    for id in conversion.requested.values.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
      let requested = conversion.requested.values[id]!
      if id == .kelvin && conversion.requested.whiteBalance != .temperature { continue }
      if metadata.unrecognized.contains(id) {
        return reject(id.rawValue, requested.label, "unrecognized camera value")
      }
      if let observed = metadata.rendering[id] {
        let matches: Bool
        if case .grain(let wanted) = requested, case .grain(let actual) = observed {
          matches =
            wanted.strength == actual.strength && (actual.size == nil || wanted.size == actual.size)
        } else {
          matches = requested == observed
        }
        if !matches { return reject(id.rawValue, requested.label, observed.label) }
        evidence[id] = .jpegObserved
      } else if required.contains(id) {
        return reject(id.rawValue, requested.label, "missing camera metadata")
      } else {
        evidence[id] = .profileConfirmed
      }
    }
    let report = EffectiveRecipeReport(
      supportVersion: conversion.supportVersion, requested: conversion.requested,
      dormantGrainSizeNotSerialized: conversion.requested.grain.strength == .off,
      inactiveKelvinPreserved: conversion.requested.whiteBalance != .temperature,
      lensOptimizerRequested: conversion.expectedLensOptimizer, lensOptimizerEffective: lmo,
      lensOptimizerAdjusted: false,
      evidence:
        "Exact profile readback and model-qualified JPEG identity/FINE/geometry; evidence source recorded per setting.",
      evidenceBySetting: evidence)
    return .init(metadata: metadata, admission: .accepted(report))
  }
}
