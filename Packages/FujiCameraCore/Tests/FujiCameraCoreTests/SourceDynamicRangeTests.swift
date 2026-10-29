import Foundation
import Testing

@testable import FujiCameraCore

struct SourceDynamicRangeTests {
  @Test func unrecognizedCaptureDRInDecodedMetadataStillUses100() throws {
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(xe3Metadata())) as? [String: Any])
    object["captureDynamicRange"] = 300
    let source = try JSONDecoder().decode(RAWMetadata.self, from: JSONSerialization.data(withJSONObject: object))
    let patch = try XE3WorkingProfile.make(
      baseline: xe3Baseline(), settings: xe3Settings(), source: source)
    #expect(patch.bytes.subdata(in: 533..<537) == Data([100, 0, 0, 0]))
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["FUJI_DR_PRIVATE_RAF"] != nil))
  func actualAuditedRAFReportsCapture200AndCapsRequested400() throws {
    let url = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["FUJI_DR_PRIVATE_RAF"]))
    let token = ResourceToken(assetID: "private-dr-check", role: .primaryOriginal,
      contentTypeIdentifier: "com.fujifilm.raw-image", format: .raf,
      originalFilename: "private.RAF", discriminator: "dr-check")
    let raw = try RAFMetadataReader().prepare(
      .init(token: token, fileURL: url, checksum: ResourceChecksum.sha256(url)))
    #expect(raw.metadata.captureDynamicRange == 200)
    let patch = try XE3WorkingProfile.make(
      baseline: xe3Baseline(), settings: xe3Settings(), source: raw.metadata)
    #expect(patch.bytes.subdata(in: 533..<537) == Data([200, 0, 0, 0]))
    #expect(patch.requested.dynamicRange == 400)
  }

  @Test(arguments: [100, 200, 400])
  func xt5UsesLowerOfCaptureAndRecipeWithoutChangingFrozenRecipe(_ capture: Int) throws {
    let fixture = try ProductionProfileFixture()
    let source = RAWMetadata(
      cameraModel: "X-T5", containerGeometry: .init(width: 7872, height: 5196),
      recordedGeometry: .init(width: 7728, height: 5152), recordedAspect: .init(width: 3, height: 2),
      cropTop: 21, cropLeft: 12, orientation: 8, captureDynamicRange: capture)
    let expected = [100: [100, 100, 100], 200: [100, 200, 200], 400: [100, 200, 400]][capture]!
    for (requested, effective) in zip([100, 200, 400], expected) {
      var properties = fixture.properties
      properties[0xD190] = UInt16(requested)
      let recipe = try fixture.bank(properties)
      let patch = try XT5WorkingProfile.make(
        baseline: fixture.baseline, recipe: recipe, metadata: source)
      #expect(patch.bytes.subdata(in: 533..<537) == drWord(effective))
      #expect(patch.settings.dynamicRange == requested)
      #expect(patch.recipeID == recipe.id && patch.settingsDigest == recipe.settingsDigest)
      #expect(recipe.importedSettings.first { $0.code == 0xD190 }?.raw == Data(drWord(requested).prefix(2)))
    }
  }

  @Test(arguments: [100, 200, 400])
  func xe3UsesLowerOfCaptureAndRecipeWithoutChangingRequestedSettings(_ capture: Int) throws {
    let resource = try sourceDRFixture(capture: UInt16(capture))
    defer { try? FileManager.default.removeItem(at: resource.fileURL) }
    let source = try RAFMetadataReader().prepare(resource).metadata
    // Literal matrix: rows are capture DR, columns are recipe DR100/200/400.
    let expected = [100: [100, 100, 100], 200: [100, 200, 200], 400: [100, 200, 400]][capture]!
    for (requested, effective) in zip([100, 200, 400], expected) {
      var settings = xe3Settings()
      settings.dynamicRange = requested
      let patch = try XE3WorkingProfile.make(
        baseline: xe3Baseline(), settings: settings, source: source)
      #expect(patch.bytes.subdata(in: 533..<537) == drWord(effective))
      #expect(patch.requested.dynamicRange == requested)
      #expect(patch.requested == settings)
    }
  }

  @Test(arguments: [UInt16?.none, 0, 300, 65535])
  func missingOrUnrecognizedCaptureDRUses100WithoutRejectingRecipe(_ capture: UInt16?) throws {
    let resource = try sourceDRFixture(capture: capture)
    defer { try? FileManager.default.removeItem(at: resource.fileURL) }
    let source = try RAFMetadataReader().prepare(resource).metadata
    let patch = try XE3WorkingProfile.make(
      baseline: xe3Baseline(), settings: xe3Settings(), source: source)
    #expect(patch.bytes.subdata(in: 533..<537) == Data([100, 0, 0, 0]))
    #expect(patch.requested.dynamicRange == 400)
  }

  @Test func malformedCaptureDRMetadataUses100WithoutRejectingRecipe() throws {
    let jpeg = CoreJPEGFixture(
      model: "X-E3", fields: [(0x1403, 4, 1, Data([200, 0, 0, 0]))]
    ).inject(into: try ObjectObservationFixture.jpeg())
    let resource = try xe3RAFFixture(embeddedJPEG: jpeg)
    defer { try? FileManager.default.removeItem(at: resource.fileURL) }
    let source = try RAFMetadataReader().prepare(resource).metadata
    let patch = try XE3WorkingProfile.make(
      baseline: xe3Baseline(), settings: xe3Settings(), source: source)
    #expect(patch.bytes.subdata(in: 533..<537) == Data([100, 0, 0, 0]))
  }
}

private func sourceDRFixture(capture: UInt16?) throws -> LocalResource {
  let fields: [(UInt16, UInt16, UInt32, Data)] = capture.map {
    [(0x1403, 3, 1, Data([UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)]))]
  } ?? []
  let jpeg = CoreJPEGFixture(model: "X-E3", fields: fields).inject(
    into: try ObjectObservationFixture.jpeg())
  return try xe3RAFFixture(embeddedJPEG: jpeg)
}

private func drWord(_ value: Int) -> Data {
  Data([UInt8(truncatingIfNeeded: value), UInt8(value >> 8), 0, 0])
}
