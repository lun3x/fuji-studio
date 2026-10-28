import Foundation
import Testing

@testable import FujiCameraCore

struct RecipeEditRoundTripTests {
  @Test func changedWBReassessesSelectedSharedDependency() throws {
    let original = try XE3BackupRecipeCodec.decode(
      syntheticXE3Backup(), context: xe3RecipeContext(), importedAt: Date()
    ).recipes[0]
    let codecs = RecipeCodecRegistry()
    let shade = try codecs.encodeEditedValues(
      [.whiteBalance: .whiteBalance(.shade)], preserving: original)
    #expect(shade.importedSettings.first { $0.code == 13 }?.raw == Data([0xbd, 1]))
    #expect(codecs.assess(shade).issues.isEmpty)
    #expect(try codecs.requireSettings(shade).whiteBalance == .shade)
    #expect(try codecs.editableValues(shade)[.whiteBalanceRed] == .integer(-4))
  }
  @Test func mixedModelOfflineEditPreservesUnknownBytes() throws {
    let xt5 = try ProductionOperationFixture()
    defer { xt5.remove() }
    var xe3 = try XE3BackupRecipeCodec.decode(
      syntheticXE3Backup(), context: xe3RecipeContext(), importedAt: Date()
    ).recipes[0]
    var p = try XE3NativeRecipeFields.properties(xe3)
    p[99] = Data([0xaa, 0xbb])
    xe3 = try XE3RecipeCodec.recipe(
      slot: 1, nameData: xe3.importedName, properties: p, context: xe3.cameraContext,
      importedAt: xe3.importedAt)
    for original in [xt5.profile.bank, xe3] {
      let codecs = RecipeCodecRegistry()
      let before = try codecs.editableValues(original)
      #expect(before[.whiteBalanceRed] != nil)
      let changed = try codecs.encodeEditedValues(
        [.whiteBalanceRed: .integer(2)], preserving: original)
      #expect(try codecs.editableValues(changed)[.whiteBalanceRed] == .integer(2))
      #expect(changed.id != original.id && changed.settingsDigest != original.settingsDigest)
      #expect(changed.importedName == original.importedName)
      let redCode: UInt16 = original.cameraContext.model == "X-E3" ? 5 : 0xD19A
      #expect(
        changed.importedSettings.filter { $0.code != redCode }
          == original.importedSettings.filter { $0.code != redCode })
    }
  }
  @Test func unknownKnownFieldCanRemainWhileAnotherIsEdited() throws {
    let fixture = try ProductionOperationFixture()
    defer { fixture.remove() }
    var p = fixture.profile.properties
    p[0xD192] = 99
    let snapshot = try fixture.profile.bank(p)
    let codecs = RecipeCodecRegistry()
    #expect(try codecs.editableValues(snapshot)[.film] == nil)
    let edited = try codecs.encodeEditedValues([.sharpness: .integer(10)], preserving: snapshot)
    #expect(edited.importedSettings.first { $0.code == 0xD192 }?.raw == Data([99, 0]))
    #expect(try codecs.editableValues(edited)[.sharpness] == .integer(10))
    #expect(!codecs.assess(edited).issues.isEmpty)
  }
}
