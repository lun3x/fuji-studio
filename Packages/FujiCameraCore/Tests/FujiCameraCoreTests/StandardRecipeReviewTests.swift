import Foundation
import Testing

@testable import FujiCameraCore

struct StandardRecipeReviewTests {
  @Test(arguments: [UInt64(0), 1, 42])
  func sourceAvailabilityUsesItsOwnMakerNoteFlag(_ flag: UInt64) throws {
    let payload = [flag, 2, 3].reduce(into: Data()) { bytes, word in
      bytes.append(contentsOf: (0..<8).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) })
    }
    let jpeg = CoreJPEGFixture(
      model: "X-E3", lensOptimizer: 0,
      fields: [(0x4534, 5, 3, payload)]
    ).inject(into: try ObjectObservationFixture.jpeg())
    let resource = try xe3RAFFixture(embeddedJPEG: jpeg)
    defer { try? FileManager.default.removeItem(at: resource.fileURL) }
    let source = try RAFMetadataReader().prepare(resource).metadata
    #expect(source.captureLensOptimizer == false)
    #expect(source.lensOptimizerAvailable == (flag <= 1 ? flag == 1 : nil))
    #expect(source.effectiveLensOptimizer(for: true) == (flag != 0))
  }

  @Test func malformedAvailabilityFlagIsUnknownRatherThanTheCapturedSetting() throws {
    let jpeg = CoreJPEGFixture(
      model: "X-E3", lensOptimizer: 0,
      fields: [(0x4534, 4, 1, Data([0, 0, 0, 0]))]
    )
    .inject(into: try ObjectObservationFixture.jpeg())
    let resource = try xe3RAFFixture(embeddedJPEG: jpeg)
    defer { try? FileManager.default.removeItem(at: resource.fileURL) }
    let source = try RAFMetadataReader().prepare(resource).metadata
    #expect(source.lensOptimizerAvailable == nil)
    #expect(source.effectiveLensOptimizer(for: true))
  }
  @Test func capturedLensOptimizerOffDoesNotProveThePhotoIsIncompatible() {
    let source = RAWMetadata(
      cameraModel: "X-T5", containerGeometry: .init(width: 7872, height: 5196),
      recordedGeometry: .init(width: 7728, height: 5152),
      recordedAspect: .init(width: 3, height: 2),
      cropTop: 21, cropLeft: 12, orientation: 8, captureLensOptimizer: false)
    #expect(source.effectiveLensOptimizer(for: true))
    #expect(!source.effectiveLensOptimizer(for: false))
  }

  @Test func unreadBankSavedISORequiresAnExplicitSelection() throws {
    let snapshot = try XE3BackupRecipeCodec.decode(
      syntheticXE3Backup(), context: xe3RecipeContext(), importedAt: Date()
    ).recipes[0]
    #expect(snapshot.standardRecipe.invalidSettings.contains(.iso))
    // ISO cannot change an existing RAF and does not block the other conversion settings.
    #expect(RecipeCodecRegistry().assess(snapshot).issues.isEmpty)
  }

  @Test func longExposureNoiseReductionOnCannotBeSilentlyIgnored() throws {
    let f = try ProductionProfileFixture()
    var recipe = f.bank.standardRecipe
    recipe.setValue(.integer(1), for: .longExposureNoiseReduction)
    let assessment = RecipeCodecRegistry().assess(
      f.bank.replacingStandardRecipe(recipe, name: f.bank.name))
    #expect(!assessment.issues.isEmpty)
  }

  @Test func conversionRefusalRetainsSettingIdentityAndRequestedValue() throws {
    let f = try ProductionProfileFixture()
    var recipe = f.bank.standardRecipe
    recipe.setValue(.option(.adobeRGB), for: .colorSpace)
    let assessment = RecipeCodecRegistry().assess(
      f.bank.replacingStandardRecipe(recipe, name: f.bank.name))
    let payload = String(decoding: try JSONEncoder().encode(assessment.issues), as: UTF8.self)
    #expect(payload.contains("colorSpace"))
    #expect(payload.contains("adobeRGB"))
  }
}
