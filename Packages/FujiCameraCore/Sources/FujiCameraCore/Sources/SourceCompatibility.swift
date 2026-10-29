import Foundation

public enum SourceCompatibility {
  public static func detected(_ metadata: RAWMetadata) -> RAWCompatibility {
    // Recognition allows original sensor viewing; adapter admission still checks source class.
    ["X-T5", "X-E3"].contains(metadata.cameraModel)
      ? .supported(model: metadata.cameraModel) : .incompatible(model: metadata.cameraModel)
  }
  public static func assess(_ metadata: RAWMetadata, for support: VerifiedCameraSupport)
    -> RAWCompatibility
  {
    guard metadata.cameraModel == support.model else {
      return .incompatible(model: metadata.cameraModel)
    }
    do {
      switch metadata.cameraModel {
      case "X-T5": try XT5WorkingProfile.validateSource(metadata)
      case "X-E3": try XE3SourceRules.validate(metadata)
      default: return .incompatible(model: metadata.cameraModel)
      }
      return .supported(model: metadata.cameraModel)
    } catch { return .incompatible(model: metadata.cameraModel) }
  }
}
