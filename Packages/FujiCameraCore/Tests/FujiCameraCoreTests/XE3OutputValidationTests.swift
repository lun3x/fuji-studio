import Foundation
import Testing

@testable import FujiCameraCore

struct XE3OutputValidationTests {
  @Test func qualifiedSharpnessWinsOverCoarseEXIF() throws {
    var fields = xe3MakerFields()
    fields[0x1001] = short(0x84)
    let fixture = CoreJPEGFixture(
      model: "X-E3", lensOptimizer: 1, fields: entries(fields), coarseSharpness: 2)
    let observed = try FujiJPEGMetadataReader.read(fixture.jpeg)
    #expect(observed.rendering[.sharpness] == .integer(10))
    #expect(observed.rendering[.whiteBalanceRed] == .integer(-4))
    #expect(observed.rendering[.whiteBalanceBlue] == .integer(-2))
    #expect(observed.rendering[.highlight] == .integer(-10))
    #expect(observed.rendering[.noiseReduction] == .integer(-4))
  }
  @Test func actualJPEGGeometryAndAllRequiredSettingsAdmitFineOutput() throws {
    let fixture = CoreJPEGFixture(
      model: "X-E3", lensOptimizer: 1, fields: entries(xe3MakerFields()))
    let image = fixture.inject(into: try ObjectObservationFixture.jpeg())
    let result = try XE3Adapter().validateOutput(image, conversion: conversion())
    guard case .accepted(let report) = result.admission else {
      Issue.record("Matching observed settings must admit output")
      return
    }
    #expect(result.metadata.width == 4 && result.metadata.height == 6)
    #expect(report.evidenceBySetting?[.whiteBalanceRed] == .jpegObserved)
    #expect(report.requested.colorChrome == nil)
  }
  @Test func readbackDoesNotExcuseKelvinMismatch() throws {
    var fields = xe3MakerFields()
    fields[0x1005] = short(2500)
    let image = CoreJPEGFixture(model: "X-E3", lensOptimizer: 1, fields: entries(fields)).inject(
      into: try ObjectObservationFixture.jpeg())
    var requested = xe3Settings()
    requested.kelvin = 5310
    let result = try XE3Adapter().validateOutput(image, conversion: conversion(requested))
    guard case .rejected(let mismatch) = result.admission else {
      Issue.record("Do not publish silently adjusted Kelvin")
      return
    }
    #expect(mismatch.field == "kelvin")
    #expect(mismatch.requested.contains("5310") && mismatch.observed.contains("2500"))
  }
  @Test func missingRequiredEvidenceBlocksPublication() throws {
    var fields = xe3MakerFields()
    fields[0x100a] = nil
    let image = CoreJPEGFixture(model: "X-E3", lensOptimizer: 1, fields: entries(fields)).inject(
      into: try ObjectObservationFixture.jpeg())
    let result = try XE3Adapter().validateOutput(image, conversion: conversion())
    guard case .rejected = result.admission else {
      Issue.record("Missing required WB evidence must block publication")
      return
    }
  }
  @Test func monochromeSaturationIdentifiesFilterAndColorRemainsProtocolEvidence() throws {
    var fields = xe3MakerFields()
    fields[0x1401] = nil
    fields[0x1003] = short(0x503)
    let fixture = CoreJPEGFixture(model: "X-E3", lensOptimizer: 1, fields: entries(fields))
    #expect(try FujiJPEGMetadataReader.read(fixture.jpeg).rendering[.film] == .film(.acrosGreen))
    var requested = xe3Settings()
    requested.film = .acrosGreen
    let result = try XE3Adapter().validateOutput(
      fixture.inject(into: ObjectObservationFixture.jpeg()), conversion: conversion(requested))
    guard case .accepted(let report) = result.admission else {
      Issue.record("Measured monochrome encoding must render")
      return
    }
    #expect(report.evidenceBySetting?[.color] == .profileConfirmed)
  }
  private func conversion(_ settings: RecipeSettings = xe3Settings()) -> PreparedConversion {
    let metadata = RAWMetadata(
      cameraModel: "X-E3", containerGeometry: .init(width: 4, height: 6),
      recordedGeometry: .init(width: 4, height: 6), recordedAspect: .init(width: 2, height: 3),
      cropTop: 0, cropLeft: 0, orientation: 8)
    return .init(
      bytes: Data(), requested: settings, source: metadata, supportVersion: XE3Support.identifier,
      expectedLensOptimizer: true, baselineSHA256: "baseline", candidateSHA256: "candidate")
  }
}
typealias MakerValue = (UInt16, UInt32, Data)
func short(_ value: UInt16) -> MakerValue {
  (3, 1, Data([UInt8(truncatingIfNeeded: value), UInt8(value >> 8)]))
}
func signed(_ values: [Int32]) -> MakerValue {
  (
    9, UInt32(values.count),
    values.reduce(Data()) { data, value in
      data + Data((0..<4).map { UInt8(truncatingIfNeeded: UInt32(bitPattern: value) >> ($0 * 8)) })
    }
  )
}
func xe3MakerFields() -> [UInt16: MakerValue] {
  [
    0x1001: short(3), 0x1002: short(0xff0), 0x1003: short(0x400), 0x1005: short(6300),
    0x100a: signed([-80, -40]), 0x100e: short(0x2e0), 0x1040: signed([-32]), 0x1041: signed([16]),
    0x1047: signed([0]), 0x1401: short(0x600), 0x1403: short(400),
  ]
}
func entries(_ fields: [UInt16: MakerValue]) -> [(UInt16, UInt16, UInt32, Data)] {
  fields.keys.sorted().map {
    let v = fields[$0]!
    return ($0, v.0, v.1, v.2)
  }
}

extension XE3OutputValidationTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["FUJI_XE3_PRIVATE_SAMPLES"] != nil))
  func suppliedC4CameraJPEGHasIndependentlyQualifiedSettings() throws {
    let root = URL(
      fileURLWithPath: try #require(ProcessInfo.processInfo.environment["FUJI_XE3_PRIVATE_SAMPLES"])
    )
    let rawURL = root.appendingPathComponent("DSCF0085.RAF")
    let jpegURL = root.appendingPathComponent("DSCF0085.JPG")
    let token = ResourceToken(
      assetID: "c4", role: .primaryOriginal, contentTypeIdentifier: "com.fujifilm.raw-image",
      format: .raf, originalFilename: "DSCF0085.RAF", discriminator: "c4")
    let source = try RAFMetadataReader().prepare(
      .init(token: token, fileURL: rawURL, checksum: ResourceChecksum.sha256(rawURL))
    ).metadata
    var settings = xe3Settings()
    settings.grain = .init(strength: .weak, size: nil)
    let conversion = try XE3WorkingProfile.make(
      baseline: xe3Baseline("baseline-dr400-weak"), settings: settings, source: source)
    let result = try XE3Adapter().validateOutput(Data(contentsOf: jpegURL), conversion: conversion)
    if case .rejected(let report) = result.admission { Issue.record("\(report.summary)") }
    #expect(
      result.metadata.width == 6000 && result.metadata.height == 4000
        && result.metadata.orientation == 8)
  }
}
