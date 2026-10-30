import Foundation
import Testing
@testable import FujiCameraCore

struct SourceLensOptimizerTests {
  @Test(arguments: [false, true])
  func requestedOnIsCappedByPhotoSupportWithoutChangingTheRecipe(_ supported: Bool) throws {
    let f = try ProductionProfileFixture()
    let source = RAWMetadata(cameraModel: f.metadata.cameraModel,
      containerGeometry: f.metadata.containerGeometry, recordedGeometry: f.metadata.recordedGeometry,
      recordedAspect: f.metadata.recordedAspect, cropTop: f.metadata.cropTop, cropLeft: f.metadata.cropLeft,
      orientation: f.metadata.orientation, captureDynamicRange: 200,
      captureLensOptimizer: supported)
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
    let patch = try XT5WorkingProfile.make(baseline: f.baseline, recipe: recipe, metadata: f.metadata)
    #expect(patch.bytes.subdata(in: 593..<597) == Data([2, 0, 0, 0]))
    #expect(patch.settings.lensOptimizerRequested == false)
  }
}
