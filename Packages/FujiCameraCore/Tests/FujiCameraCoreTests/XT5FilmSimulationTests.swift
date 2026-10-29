import Foundation
import Testing

@testable import FujiCameraCore

struct XT5FilmSimulationTests {
  // Recipe selector and conversion words are separate from the JPEG FilmMode tag.
  // Literal values come from pinned Fuji PTP Recipes/libfuji and ExifTool definitions.
  static let films: [(FilmSimulation, UInt16)] = [
    (.provia, 1), (.velvia, 2), (.astia, 3), (.proNegHi, 4), (.proNegStd, 5),
    (.monochrome, 6), (.monochromeYellow, 7), (.monochromeRed, 8), (.monochromeGreen, 9),
    (.sepia, 10), (.classicChrome, 11), (.acros, 12), (.acrosYellow, 13), (.acrosRed, 14),
    (.acrosGreen, 15), (.eterna, 16), (.classicNeg, 17), (.eternaBleachBypass, 18),
    (.nostalgicNeg, 19), (.realaAce, 20),
  ]

  @Test func documentedXT5FilmsEncodeTheConversionWordWithoutChangingOtherFields() throws {
    let f = try ProductionProfileFixture()
    let baseline = try XT5WorkingProfile.make(
      baseline: f.baseline, recipe: f.bank, metadata: f.metadata)
    for (film, wire) in Self.films {
      var properties = f.properties
      properties[0xD192] = wire
      let snapshot = try f.bank(properties)
      let patch = try XT5WorkingProfile.make(
        baseline: f.baseline, recipe: snapshot, metadata: f.metadata)
      #expect(patch.settings.film == film)
      #expect(patch.bytes.subdata(in: 541..<545) == Data([UInt8(wire), 0, 0, 0]))
      #expect(patch.bytes.prefix(541) == baseline.bytes.prefix(541))
      #expect(patch.bytes.dropFirst(545) == baseline.bytes.dropFirst(545))
      #expect(
        RecipeCodecRegistry.xt5Capabilities.settings[.film]?.accepts(.film(film), rendering: true)
          == true)
    }
  }

  @Test func filmMetadataUsesJPEGCodesAndRejectsAResultWithTheWrongFilm() throws {
    let f = try ProductionProfileFixture()
    for (film, jpegCode): (FilmSimulation, UInt16) in [
      (.provia, 0), (.astia, 0x120), (.velvia, 0x200), (.proNegStd, 0x500),
      (.proNegHi, 0x501), (.classicChrome, 0x600), (.eterna, 0x700), (.classicNeg, 0x800),
      (.eternaBleachBypass, 0x900), (.nostalgicNeg, 0xa00), (.realaAce, 0xb00),
    ] {
      let fixture = CoreJPEGFixture(
        lensOptimizer: 1,
        fields: [(0x1401, 3, 1, Data([UInt8(truncatingIfNeeded: jpegCode), UInt8(jpegCode >> 8)]))])
      let observed = try FujiJPEGMetadataReader.read(fixture.jpeg)
      #expect(observed.rendering[.film] == .film(film))
      #expect(!observed.unrecognized.contains(.film))
      var requested = try XT5WorkingProfile.normalize(f.bank)
      requested.film = film
      let conversion = PreparedConversion(
        bytes: Data(), requested: requested, source: f.metadata,
        supportVersion: XT5WorkingProfile.supportVersion, expectedLensOptimizer: true,
        baselineSHA256: "baseline", candidateSHA256: "candidate")
      let metadata = ValidatedJPEGMetadata(
        width: 4, height: 6, orientation: 8, make: "FUJIFILM",
        model: "X-T5", quality: .fine, lensOptimizer: true, rendering: observed.rendering,
        unrecognized: observed.unrecognized)
      let assessment = try CameraOutputAssessment.assess(
        metadata: metadata, conversion: conversion, required: [.film])
      guard case .accepted = assessment.admission else {
        Issue.record("Correct JPEG film metadata must admit \(film)")
        continue
      }
      requested.film = film == .astia ? .classicChrome : .astia
      let wrong = PreparedConversion(
        bytes: Data(), requested: requested, source: f.metadata,
        supportVersion: XT5WorkingProfile.supportVersion, expectedLensOptimizer: true,
        baselineSHA256: "baseline", candidateSHA256: "candidate")
      let rejected = try CameraOutputAssessment.assess(
        metadata: metadata, conversion: wrong, required: [.film])
      guard case .rejected(let issue) = rejected.admission else {
        Issue.record("A different returned film must be rejected")
        continue
      }
      #expect(issue.field == "film")
    }
  }
}
