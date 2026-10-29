import Foundation
import Testing

@testable import FujiCameraCore

struct XT5GrainMappingTests {
  // Literal native values from the pinned properties.md grain table.
  static let writable: [(UInt16, GrainSettings)] = [
    (1, .init(strength: .off, size: .small)),
    (2, .init(strength: .weak, size: .small)),
    (3, .init(strength: .strong, size: .small)),
    (4, .init(strength: .weak, size: .large)),
    (5, .init(strength: .strong, size: .large)),
  ]

  @Test func fullAndPartialCodecsUsePublishedGrainValues() throws {
    let f = try ProductionProfileFixture()
    let codecs = RecipeCodecRegistry()
    for (wire, grain) in Self.writable {
      var properties = f.properties
      properties[0xD195] = wire
      let imported = try f.bank(properties)
      #expect(try codecs.editableSettings(imported).grain == grain)
      #expect(try codecs.editableValues(imported)[.grain] == .grain(grain))

      var settings = try codecs.editableSettings(f.bank)
      settings.grain = grain
      let partial = try codecs.encodeEditedValues([.grain: .grain(grain)], preserving: f.bank)
      let full = try codecs.encodeEditedRecipe(settings, preserving: f.bank)
      for edited in [partial, full] {
        #expect(edited.importedSettings.first { $0.code == 0xD195 }?.raw == Data([UInt8(wire), 0]))
        #expect(try codecs.editableSettings(edited).grain == grain)
        #expect(
          edited.importedSettings.filter { $0.code != 0xD195 }
            == f.bank.importedSettings.filter { $0.code != 0xD195 })
      }
    }
  }

  @Test func offReadbacksArePreservedUntilGrainIsExplicitlyEdited() throws {
    let f = try ProductionProfileFixture()
    let codecs = RecipeCodecRegistry()
    for (wire, size): (UInt16, GrainSize) in [(6, .small), (7, .large)] {
      var properties = f.properties
      properties[0xD195] = wire
      let imported = try f.bank(properties)
      #expect(try codecs.editableSettings(imported).grain == .init(strength: .off, size: size))
      let otherEdit = try codecs.encodeEditedValues(
        [.sharpness: .integer(10)], preserving: imported)
      #expect(
        otherEdit.importedSettings.first { $0.code == 0xD195 }?.raw == Data([UInt8(wire), 0]))
      var settings = try codecs.editableSettings(imported)
      settings.sharpnessTenths = 10
      let fullOtherEdit = try codecs.encodeEditedRecipe(settings, preserving: imported)
      #expect(
        fullOtherEdit.importedSettings.first { $0.code == 0xD195 }?.raw == Data([UInt8(wire), 0]))
      let off = try codecs.encodeEditedValues(
        [.grain: .grain(.init(strength: .off, size: size))], preserving: imported)
      #expect(off.importedSettings.first { $0.code == 0xD195 }?.raw == Data([1, 0]))
    }
    var settings = try codecs.editableSettings(f.bank)
    settings.grain = .init(strength: .off, size: .large)
    let full = try codecs.encodeEditedRecipe(settings, preserving: f.bank)
    #expect(full.importedSettings.first { $0.code == 0xD195 }?.raw == Data([1, 0]))
  }

  @Test func canonicalOffRetainsExistingRenderingBehavior() throws {
    let f = try ProductionProfileFixture()
    let edited = try RecipeCodecRegistry().encodeEditedValues(
      [.grain: .grain(.init(strength: .off, size: .small))], preserving: f.bank)
    let profile = try XT5WorkingProfile.make(
      baseline: f.baseline, recipe: edited, metadata: f.metadata)
    #expect(profile.settings.grain.strength == .off)
    #expect(profile.bytes[545..<549] == Data([1, 0, 0, 0]))
    for wire: UInt16 in [2, 4, 5] {
      var properties = f.properties
      properties[0xD195] = wire
      #expect(throws: CameraServiceError.unsupportedSettings) {
        try XT5WorkingProfile.normalize(f.bank(properties))
      }
    }
  }
}
