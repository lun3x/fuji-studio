import Foundation
import Testing

@testable import FujiCameraCore

struct RecipeOptionValuesTests {
  // Literal expectations from the pinned recipe property reference, independently
  // checked against the pre-existing film 1...15 and nine WB mappings.
  static let filmNames = [
    "provia", "velvia", "astia", "proNegHi", "proNegStd", "monochrome",
    "monochromeYellow", "monochromeRed", "monochromeGreen", "sepia", "classicChrome",
    "acros", "acrosYellow", "acrosRed", "acrosGreen", "eterna", "classicNeg",
    "eternaBleachBypass", "nostalgicNeg", "realaAce",
  ]
  static let whiteBalances: [(UInt16, String)] = [
    (2, "auto"), (0x8020, "autoWhitePriority"), (0x8021, "autoAmbiencePriority"),
    (0x8008, "custom1"), (0x8009, "custom2"), (0x800a, "custom3"),
    (0x8007, "temperature"), (4, "daylight"), (0x8006, "shade"),
    (0x8001, "fluorescent1"), (0x8002, "fluorescent2"), (0x8003, "fluorescent3"),
    (6, "incandescent"), (8, "underwater"),
  ]

  @Test func xt5OffersCompleteDocumentedChoicesWithExactWireValues() throws {
    let f = try ProductionProfileFixture()
    let codecs = RecipeCodecRegistry()
    let capabilities = try codecs.capabilities(for: f.bank.cameraContext)
    let films = try #require(capabilities.settings[.film])
    let wb = try #require(capabilities.settings[.whiteBalance])
    #expect(films.editableChoices.count == 20)
    #expect(wb.editableChoices.count == 14)
    #expect(
      capabilities.settings[.dynamicRange]?.editableChoices.map(\.value)
        == [0, 100, 200, 400].map(RecipeSettingValue.integer))

    for (offset, name) in Self.filmNames.enumerated() {
      let film = try #require(FilmSimulation(rawValue: name))
      try checkEdit(.film, .film(film), code: 0xD192, wire: UInt16(offset + 1), original: f.bank)
    }
    for (wire, name) in Self.whiteBalances {
      let mode = try #require(WhiteBalanceMode(rawValue: name))
      try checkEdit(.whiteBalance, .whiteBalance(mode), code: 0xD199, wire: wire, original: f.bank)
    }
    for dr in [0, 100, 200, 400] {
      try checkEdit(.dynamicRange, .integer(dr), code: 0xD190, wire: UInt16(dr), original: f.bank)
    }
  }

  @Test func allAdvertisedDiscreteChoicesCanBeSavedWithoutChangingOtherFields() throws {
    let f = try ProductionProfileFixture()
    let codecs = RecipeCodecRegistry()
    let originals = [
      f.bank,
      try XE3BackupRecipeCodec.decode(
        syntheticXE3Backup(), context: xe3RecipeContext(), importedAt: Date()
      ).recipes[0],
    ]
    for original in originals {
      for (id, capability) in try codecs.capabilities(for: original.cameraContext).settings {
        for choice in capability.editableChoices {
          let edited = try codecs.encodeEditedValues([id: choice.value], preserving: original)
          #expect(try codecs.editableValues(edited)[id] == choice.value)
          #expect(edited.importedName == original.importedName)
        }
      }
    }
  }

  @Test func xe3ChoicesRemainRestrictedToItsOwnNativeMappings() throws {
    let capabilities = XE3Capabilities.measured
    #expect(capabilities.settings[.film]?.editableChoices.count == 15)
    #expect(capabilities.settings[.whiteBalance]?.editableChoices.count == 9)
    #expect(
      capabilities.settings[.dynamicRange]?.editableChoices.map(\.value)
        == [0, 100, 200, 400].map(RecipeSettingValue.integer))
    #expect(capabilities.settings[.dynamicRange]?.accepts(.integer(0), rendering: true) == false)
  }

  @Test func newSelectorKnowledgeDoesNotClaimMeasuredRenderingSupport() throws {
    let f = try ProductionProfileFixture()
    let codecs = RecipeCodecRegistry()
    for (id, value): (RecipeSettingID, RecipeSettingValue) in [
      (.dynamicRange, .integer(200)), (.whiteBalance, .whiteBalance(.daylight)),
    ] {
      let capability = try #require(RecipeCodecRegistry.xt5Capabilities.settings[id])
      #expect(capability.accepts(value, rendering: false))
      #expect(!capability.accepts(value, rendering: true))
      let edited = try codecs.encodeEditedValues([id: value], preserving: f.bank)
      #expect(!codecs.assess(edited).issues.isEmpty)
    }
  }

  private func checkEdit(
    _ id: RecipeSettingID, _ value: RecipeSettingValue, code: UInt16, wire: UInt16,
    original: RecipeSnapshot
  ) throws {
    let codecs = RecipeCodecRegistry()
    let edited = try codecs.encodeEditedValues([id: value], preserving: original)
    #expect(
      edited.importedSettings.first { $0.code == code }?.raw
        == Data([UInt8(truncatingIfNeeded: wire), UInt8(wire >> 8)]))
    #expect(try codecs.editableValues(edited)[id] == value)
    #expect(
      edited.importedSettings.filter { $0.code != code }
        == original.importedSettings.filter { $0.code != code })
  }
}
