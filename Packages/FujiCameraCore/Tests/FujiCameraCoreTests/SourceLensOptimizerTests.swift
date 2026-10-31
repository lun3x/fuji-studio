import Foundation
import Testing

@testable import FujiCameraCore

struct SourceLensOptimizerTests {
  @Test(arguments: [UInt32(0), 1])
  func originalPhotoMetadataRetainsCaptureStateWithoutInferringAvailability(_ observed: UInt32)
    throws
  {
    let jpeg = CoreJPEGFixture(model: "X-E3", lensOptimizer: observed)
      .inject(into: try ObjectObservationFixture.jpeg())
    let resource = try xe3RAFFixture(embeddedJPEG: jpeg)
    defer { try? FileManager.default.removeItem(at: resource.fileURL) }
    let metadata = try RAFMetadataReader().prepare(resource).metadata
    #expect(metadata.captureLensOptimizer == (observed == 1))
    #expect(metadata.lensOptimizerAvailable == nil)
  }

  @Test func xe3ProfileAlsoCapsRequestedOnToOffForThePhoto() throws {
    let f = xe3Metadata()
    let source = RAWMetadata(
      cameraModel: f.cameraModel, containerGeometry: f.containerGeometry,
      recordedGeometry: f.recordedGeometry, recordedAspect: f.recordedAspect,
      cropTop: f.cropTop, cropLeft: f.cropLeft, orientation: f.orientation,
      compression: f.compression, bitDepth: f.bitDepth, rafVersion: f.rafVersion,
      captureDynamicRange: 200, captureLensOptimizer: false, lensOptimizerAvailable: false)
    var settings = xe3Settings()
    settings.lensOptimizerRequested = true
    let patch = try XE3WorkingProfile.make(
      baseline: xe3Baseline(), settings: settings, source: source)
    #expect(patch.bytes.subdata(in: 593..<597) == Data([2, 0, 0, 0]))
    #expect(patch.requested.lensOptimizerRequested == true)
    #expect(!patch.expectedLensOptimizer)
  }
  @Test(arguments: [false, true])
  func requestedOnIsCappedByPhotoSupportWithoutChangingTheRecipe(_ supported: Bool) throws {
    let f = try ProductionProfileFixture()
    let source = RAWMetadata(
      cameraModel: f.metadata.cameraModel,
      containerGeometry: f.metadata.containerGeometry,
      recordedGeometry: f.metadata.recordedGeometry,
      recordedAspect: f.metadata.recordedAspect, cropTop: f.metadata.cropTop,
      cropLeft: f.metadata.cropLeft,
      orientation: f.metadata.orientation, captureDynamicRange: 200,
      captureLensOptimizer: false, lensOptimizerAvailable: supported)
    let patch = try XT5WorkingProfile.make(baseline: f.baseline, recipe: f.bank, metadata: source)
    #expect(patch.bytes.subdata(in: 593..<597) == Data([supported ? 1 : 2, 0, 0, 0]))
    #expect(patch.settings.lensOptimizerRequested == true)
    #expect(patch.settings.dynamicRange == 400)
    #expect(patch.effectiveDynamicRange == 200)
    #expect(f.bank.standardRecipe.value(for: .lensOptimizer) == .integer(1))
  }

  @Test func offStaysOffForSupportedPhotos() throws {
    let f = try ProductionProfileFixture()
    var standard = f.bank.standardRecipe
    standard.setValue(.integer(0), for: .lensOptimizer)
    let recipe = f.bank.replacingStandardRecipe(standard, name: f.bank.name)
    let patch = try XT5WorkingProfile.make(
      baseline: f.baseline, recipe: recipe, metadata: f.metadata)
    #expect(patch.bytes.subdata(in: 593..<597) == Data([2, 0, 0, 0]))
    #expect(patch.settings.lensOptimizerRequested == false)
  }
}
