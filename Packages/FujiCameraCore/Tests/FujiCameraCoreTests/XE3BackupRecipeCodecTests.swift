import Foundation
import Testing

@testable import FujiCameraCore

struct XE3BackupRecipeCodecTests {
  @Test(.enabled(if:ProcessInfo.processInfo.environment["FUJI_XE3_PRIVATE_BACKUP"] != nil))
  func restoredPrivateBackupHasSevenRenderableBanks() throws {
    let path=try #require(ProcessInfo.processInfo.environment["FUJI_XE3_PRIVATE_BACKUP"])
    let result=try decode(Data(contentsOf:URL(fileURLWithPath:path)))
    #expect(result.recipes.count == 7)
    for recipe in result.recipes { #expect(XE3RecipeCodec.assess(recipe).issues.isEmpty) }
  }
  @Test func backupFreezesSharedWBIntoSnapshot() throws {
    var data = syntheticXE3Backup()
    let original = try decode(data)
    #expect(original.declaredSlots.map(\.id) == Array(1...7))
    #expect(original.recipes.map(\.slot) == Array(1...7))
    let temperature = try XE3RecipeCodec.decode(original.recipes[0])
    #expect(temperature.kelvin == 6300)
    #expect(temperature.whiteBalanceRed == -4 && temperature.whiteBalanceBlue == -2)
    let auto = try XE3RecipeCodec.decode(original.recipes[1])
    #expect(auto.whiteBalanceRed == 3 && auto.whiteBalanceBlue == -4)
    let daylight = try XE3RecipeCodec.decode(original.recipes[2])
    #expect(daylight.whiteBalanceRed == 2 && daylight.whiteBalanceBlue == -4)
    #expect(original.recipes[0].name.isEmpty)
    #expect(original.recipes[0].importedName.count == 16)
    data[441] = 12
    let changed = try decode(data)
    #expect(changed.recipes[0].settingsDigest != original.recipes[0].settingsDigest)
    #expect(changed.recipes[1].settingsDigest == original.recipes[1].settingsDigest)
    #expect(try XE3RecipeCodec.decode(original.recipes[0]).whiteBalanceRed == -4)
  }
  @Test func neutralUncalibratedWBIsStillUnsupported() throws {
    var data = syntheticXE3Backup()
    data[3909 - 33] = 2
    let snapshot = try decode(data).recipes[0]
    #expect(
      XE3RecipeCodec.assess(snapshot).issues.contains(
        .unvalidatedDependency("shared white-balance shift")))
    #expect(try XE3RecipeCodec.decode(snapshot).whiteBalanceRed == 0)
    #expect(snapshot.importedSettings.first { $0.code == 13 }?.raw == Data([0xbd, 1]))
  }
  @Test func unknownValuesRemainPassiveAndComplete() throws {
    for offset in [3909, 3909 - 33, 3909 + 3, 3909 + 7, 3909 - 7] {
      var data = syntheticXE3Backup()
      data[offset] = 255
      let result = try decode(data)
      #expect(result.recipes.count == 7)
      #expect(!XE3RecipeCodec.assess(result.recipes[0]).issues.isEmpty)
      #expect(result.recipes[0].importedSettings.contains { $0.raw == Data([255]) })
    }
  }
  @Test func allMeasuredBackupValuesUseDistinctTables() throws {
    for (offset, values, id) in [
      (0, Array(XE3NativeRecipeFields.films.keys), UInt16(1)),
      (7, Array(XE3NativeRecipeFields.colors.keys), UInt16(10)),
      (-7, Array(UInt8(0)...8), UInt16(12)),
    ] {
      for value in values {
        var data = syntheticXE3Backup()
        data[3909 + offset] = value
        let recipe = try decode(data).recipes[0]
        #expect(recipe.importedSettings.first { $0.code == id }?.raw == Data([value]))
        _ = try XE3RecipeCodec.decode(recipe)
      }
    }
  }
  @Test func malformedFramingAndUnterminatedNameRejectWholeCollection() throws {
    var badModel = syntheticXE3Backup()
    badModel[23] = 53
    var badName = syntheticXE3Backup()
    badName.replaceSubrange(3978..<3994, with: Data(repeating: 65, count: 16))
    for data in [
      Data(syntheticXE3Backup().dropLast()), syntheticXE3Backup() + Data([0]), badModel, badName,
    ] {
      #expect(throws: (any Error).self) { try decode(data) }
    }
  }
  private func decode(_ data: Data) throws -> DecodedRecipeCollection {
    try XE3BackupRecipeCodec.decode(
      data, context: xe3RecipeContext(), importedAt: Date(timeIntervalSince1970: 0))
  }
}
func xe3RecipeContext() -> RecipeCameraContext {
  .init(
    model: "X-E3", firmware: "1.30", capability: XE3Support.identifier, sessionIdentity: UUID(),
    sessionGeneration: 1)
}
func syntheticXE3Backup() -> Data {
  try! Data(
    contentsOf: Bundle.module.url(
      forResource: "xe3-bank-backup-synthetic", withExtension: "bin",
      subdirectory: "Fixtures/XE3/1.30")!)
}
