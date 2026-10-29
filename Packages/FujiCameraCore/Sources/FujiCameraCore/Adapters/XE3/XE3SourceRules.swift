import Foundation

public enum XE3SourceRules {
  public static func validate(_ metadata: RAWMetadata) throws {
    guard metadata.cameraModel == "X-E3",
      metadata.recordedGeometry == PixelSize(width: 6000, height: 4000),
      metadata.recordedAspect == PixelSize(width: 3, height: 2),
      [1, 8].contains(metadata.orientation), metadata.rafVersion == "0130", metadata.bitDepth == 14,
      metadata.cropLeft == 16
    else { throw CameraServiceError.unsupportedSource }
    switch metadata.compression {
    case .lossless:
      guard metadata.containerGeometry == PixelSize(width: 6048, height: 4038),
        metadata.cropTop == 21
      else { throw CameraServiceError.unsupportedSource }
    case .uncompressed:
      guard metadata.containerGeometry == PixelSize(width: 6160, height: 4032),
        metadata.cropTop == 16
      else { throw CameraServiceError.unsupportedSource }
    default: throw CameraServiceError.unsupportedSource
    }
  }
}
