import Foundation
import Testing

@testable import FujiCameraCore

struct SourceDynamicRangeTests {
  @Test(arguments: [100, 200, 400])
  func recipeAppliesAtLowerOfCaptureAndRecipeDR(_ capture: Int) throws {
    let fixture = try ProductionProfileFixture()
    let source = metadata(capture: capture)
    let expected = [100: [100, 100, 100], 200: [100, 200, 200], 400: [100, 200, 400]][capture]!
    for (requested, effective) in zip([100, 200, 400], expected) {
      var properties = fixture.properties
      properties[0xD190] = UInt16(requested)
      let recipe = try fixture.bank(properties)
      let patch = try XT5WorkingProfile.make(baseline: fixture.baseline, recipe: recipe, metadata: source)
      #expect(patch.bytes.subdata(in: 533..<537) == Data([UInt8(truncatingIfNeeded: effective), UInt8(effective >> 8), 0, 0]))
      let report = patch.effective(lensOptimizer: true)
      #expect(report.requested.dynamicRange == requested)
      #expect(report.dynamicRangeEffective == effective)
      #expect(patch.settingsDigest == recipe.settingsDigest)
    }
  }

  @Test(arguments: [Int?.none, 0, 300])
  func unknownCaptureDRStillAppliesRecipeUsing100(_ capture: Int?) throws {
    let fixture = try ProductionProfileFixture()
    let patch = try XT5WorkingProfile.make(
      baseline: fixture.baseline, recipe: fixture.bank, metadata: metadata(capture: capture))
    #expect(patch.bytes.subdata(in: 533..<537) == Data([100, 0, 0, 0]))
    #expect(patch.settings.dynamicRange == 400)
  }

  private func metadata(capture: Int?) -> RAWMetadata {
    .init(
      cameraModel: "X-T5", containerGeometry: .init(width: 7872, height: 5196),
      recordedGeometry: .init(width: 7728, height: 5152), recordedAspect: .init(width: 3, height: 2),
      cropTop: 21, cropLeft: 12, orientation: 8, captureDynamicRange: capture)
  }
}
