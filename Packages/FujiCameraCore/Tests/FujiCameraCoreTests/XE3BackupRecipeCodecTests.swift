import Foundation
import Testing

@testable import FujiCameraCore

struct XE3BackupRecipeCodecTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["FUJI_XE3_PRIVATE_BACKUP"] != nil))
  func restoredPrivateBackupHasSevenRenderableBanks() throws {
    let path = try #require(ProcessInfo.processInfo.environment["FUJI_XE3_PRIVATE_BACKUP"])
    let result = try decode(Data(contentsOf: URL(fileURLWithPath: path)))
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
  @Test(arguments: [UInt8(2), 3, 4, 5, 6])
  func calibratedPresetFreezesItsIndependentShiftPair(_ rawMode: UInt8) throws {
    let cases: [UInt8: (Int, WhiteBalanceMode, Int, Int)] = [
      2: (445, .shade, 1, 2), 3: (447, .fluorescent1, 3, 4),
      4: (449, .fluorescent2, 5, 6), 5: (451, .fluorescent3, 7, 8),
      6: (453, .incandescent, -1, -2),
    ]
    let (offset, mode, red, blue) = try #require(cases[rawMode])
    var data = syntheticXE3Backup()
    data[3909 - 33] = rawMode
    data[offset] = UInt8(9 - red)
    data[offset + 1] = UInt8(9 - blue)
    let snapshot = try decode(data).recipes[0]
    #expect(XE3RecipeCodec.assess(snapshot).issues.isEmpty)
    let previouslyBlocked = snapshot.recordingIssues([
      .unvalidatedDependency("shared white-balance shift")
    ])
    if case .unsupported = previouslyBlocked.renderingSupport(using: RecipeCodecRegistry()) {
      Issue.record("Frozen old observations must be reassessed against the verified mapping")
    }
    #expect(previouslyBlocked.settingsDigest == snapshot.settingsDigest)
    let settings = try XE3RecipeCodec.decode(snapshot)
    #expect(settings.whiteBalance == mode)
    #expect(settings.whiteBalanceRed == red && settings.whiteBalanceBlue == blue)
    #expect(
      snapshot.importedSettings.first { $0.code == 13 }?.raw
        == Data([UInt8(truncatingIfNeeded: offset), UInt8(offset >> 8)]))
    _ = try XE3WorkingProfile.make(
      baseline: xe3Baseline(), settings: settings, source: xe3Metadata())
    data[offset] = 9
    data[offset + 1] = 9
    let changed = try decode(data).recipes[0]
    #expect(changed.settingsDigest != snapshot.settingsDigest)
    #expect(try XE3RecipeCodec.decode(snapshot).whiteBalanceRed == red)
    #expect(try XE3RecipeCodec.decode(snapshot).whiteBalanceBlue == blue)
  }
  @Test func customMeasuredWBRemainsOpaqueAndUnsupported() throws {
    var data = syntheticXE3Backup()
    data[3909 - 33] = 9
    let snapshot = try decode(data).recipes[0]
    #expect(!XE3RecipeCodec.assess(snapshot).issues.isEmpty)
    #expect(snapshot.importedSettings.first { $0.code == 14 }?.raw == data.subdata(in: 433..<457))
    #expect(snapshot.importedSettings.allSatisfy { ![5, 6, 13].contains($0.code) })
    #expect(throws: CameraServiceError.unsupportedSettings) { try XE3RecipeCodec.decode(snapshot) }
  }
  @Test func verifiedPairFromAnotherModeStillCannotBeSubstituted() throws {
    var data = syntheticXE3Backup()
    data[3909 - 33] = 2
    let snapshot = try decode(data).recipes[0]
    var fields = Dictionary(
      uniqueKeysWithValues: snapshot.importedSettings.map { ($0.code, $0.raw) })
    fields[13] = Data([0xbb, 1])  // verified Daylight pair443, but this bank requests Shade
    let mismatched = try XE3RecipeCodec.recipe(
      slot: 1, nameData: snapshot.importedName, properties: fields, context: snapshot.cameraContext,
      importedAt: snapshot.importedAt)
    #expect(
      XE3RecipeCodec.assess(mismatched).issues.contains(
        .unvalidatedDependency("shared white-balance shift")))
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
