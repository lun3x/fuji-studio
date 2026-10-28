import CryptoKit
import Foundation

/// Exact measured initial state, not a general _0200 header/count grammar. Always patches fresh input.
public struct XT5WorkingProfile: Sendable {
  public static let supportVersion = "xt5-4.31-0200-observed-frame-v1"
  public static let writableOffsets = [
    533, 541, 545, 549, 553, 557, 561, 565, 569, 573, 577, 581, 585, 589, 593, 609, 617,
  ]
  public let bytes: Data
  public let recipeID: UUID
  public let settingsDigest: String
  public let settings: NormalizedRecipeSettings
  public let baselineSHA256: String, candidateSHA256: String

  public static func validateSource(_ metadata: RAWMetadata) throws {
    guard metadata.cameraModel == "X-T5",
      metadata.recordedGeometry == PixelSize(width: 7728, height: 5152),
      metadata.recordedAspect == PixelSize(width: 3, height: 2),
      (1...8).contains(metadata.orientation),
      metadata.containerGeometry.width > 0, metadata.containerGeometry.height > 0,
      metadata.cropTop >= 0, metadata.cropLeft >= 0,
      metadata.cropTop <= metadata.containerGeometry.height,
      metadata.cropLeft <= metadata.containerGeometry.width,
      metadata.recordedGeometry.width <= metadata.containerGeometry.width - metadata.cropLeft,
      metadata.recordedGeometry.height <= metadata.containerGeometry.height - metadata.cropTop
    else { throw CameraServiceError.unsupportedSource }
  }
  public static func normalize(_ recipe: RecipeSnapshot) throws -> NormalizedRecipeSettings {
    guard recipe.cameraContext.model == "X-T5", recipe.cameraContext.firmware == "4.31",
      recipe.cameraContext.capability == "X-T5_0200"
    else { throw CameraServiceError.unsupportedContext }
    let p = try properties(recipe)
    func v(_ code: UInt16) -> UInt16 { p[code]! }
    func s(_ code: UInt16) -> Int { Int(Int16(bitPattern: v(code))) }
    let tuple = [v(0xD18E), v(0xD18F), v(0xD1A3), v(0xD1A4)]
    let nr: [UInt16: Int] = [
      0x8000: -4, 0x7000: -3, 0x4000: -2, 0x3000: -1, 0x2000: 0, 0x1000: 1, 0: 2, 0x6000: 3,
      0x5000: 4,
    ]
    guard tuple[0] == 7, [2, 4].contains(tuple[1]), tuple[2] == 1, tuple[3] == 1,
      [100, 400].contains(v(0xD190)), v(0xD191) == 0, let film = SupportedFilm(rawValue: v(0xD192)),
      v(0xD193) == 0, v(0xD194) == 0, [3, 6, 7].contains(v(0xD195)),
      (1...3).contains(v(0xD196)), (1...3).contains(v(0xD197)), v(0xD198) == 1,
      let wb = SupportedWhiteBalance(rawValue: v(0xD199)), (-9...9).contains(s(0xD19A)),
      (-9...9).contains(s(0xD19B)),
      (2500...10000).contains(v(0xD19C)), let noise = nr[v(0xD1A1)],
      [UInt16(0xD19D), 0xD19E].allSatisfy({ (-20...40).contains(s($0)) && s($0) % 5 == 0 }),
      [UInt16(0xD19F), 0xD1A0].allSatisfy({ (-40...40).contains(s($0)) && s($0) % 10 == 0 }),
      (-50...50).contains(s(0xD1A2)), s(0xD1A2) % 10 == 0
    else { throw CameraServiceError.unsupportedSettings }
    return NormalizedRecipeSettings(
      supportVersion: supportVersion, film: film,
      grain: v(0xD195) == 3 ? .strongSmall : v(0xD195) == 6 ? .offSmall : .offLarge,
      dynamicRange: Int(v(0xD190)), colorChrome: Int(v(0xD196)), colorChromeBlue: Int(v(0xD197)),
      whiteBalance: wb,
      whiteBalanceRed: s(0xD19A), whiteBalanceBlue: s(0xD19B), kelvin: Int(v(0xD19C)),
      highlightTenths: s(0xD19D), shadowTenths: s(0xD19E),
      colorTenths: s(0xD19F), sharpnessTenths: s(0xD1A0), clarityTenths: s(0xD1A2),
      noiseReduction: noise, observedOpaqueTuple: tuple, lensOptimizerRequested: true)
  }
  public static func make(baseline: Data, recipe: RecipeSnapshot, metadata: RAWMetadata) throws
    -> Self
  {
    try validateSource(metadata)
    let settings = try normalize(recipe)
    guard baseline.count == 625, baseline.prefix(3) == Data([29, 0, 8]),
      baseline.subdata(in: 3..<19) == Data("FF179502".utf16.flatMap { [UInt8($0), 0] }),
      baseline[19..<513].allSatisfy({ $0 == 0 })
    else { throw CameraServiceError.unsupportedProfile }
    let measured: [Int32] = [
      2, 7, 7, 2, 0, 400, 0, 15, 1, 3, 1, 0, 3, -4, 0, 20, 20, 0, 0, 32768, 2, 1, 0, 1, 3, 0, 0, 2,
    ]
    for (i, v) in measured.enumerated() {
      guard baseline.subdata(in: 513 + i * 4..<517 + i * 4) == word(UInt32(bitPattern: v)) else {
        throw CameraServiceError.unsupportedProfile
      }
    }
    let p = try properties(recipe)
    var output = baseline
    let rules: [(Int, UInt16, Bool)] = [
      (533, 0xD190, false), (541, 0xD192, false), (549, 0xD196, false), (557, 0xD199, false),
      (561, 0xD19A, true), (565, 0xD19B, true), (569, 0xD19C, false), (573, 0xD19D, true),
      (577, 0xD19E, true), (581, 0xD19F, true), (585, 0xD1A0, true), (589, 0xD1A1, false),
      (609, 0xD197, false), (617, 0xD1A2, true),
    ]
    for (offset, code, signed) in rules {
      let v = p[code]!
      output.replaceSubrange(
        offset..<offset + 4,
        with: word(signed ? UInt32(bitPattern: Int32(Int16(bitPattern: v))) : UInt32(v)))
    }
    output.replaceSubrange(545..<549, with: word(settings.grain == .strongSmall ? 3 : 1))
    output.replaceSubrange(553..<557, with: word(2))
    output.replaceSubrange(593..<597, with: word(1))  // Explicit requested ON; effective value comes from returned JPEG.
    return Self(
      bytes: output, recipeID: recipe.id, settingsDigest: recipe.settingsDigest, settings: settings,
      baselineSHA256: hash(baseline), candidateSHA256: hash(output))
  }
  public func effective(lensOptimizer: Bool) -> EffectiveRecipeReport {
    EffectiveRecipeReport(
      supportVersion: Self.supportVersion, requested: settings,
      dormantGrainSizeNotSerialized: settings.grain != .strongSmall,
      inactiveKelvinPreserved: settings.whiteBalance != .temperature, lensOptimizerRequested: true,
      lensOptimizerEffective: lensOptimizer,
      lensOptimizerAdjusted: !lensOptimizer,
      evidence:
        "Exact profile readback; JPEG Fuji quality/context and LMO metadata. Opaque tuple accepted only within observed frame support."
    )
  }
  public static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private static func word(_ value: UInt32) -> Data {
    Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
  }
  private static func properties(_ recipe: RecipeSnapshot) throws -> [UInt16: UInt16] {
    let codes = Array(UInt16(0xD18E)...0xD1A4)
    guard recipe.importedSettings.count == codes.count,
      Set(recipe.importedSettings.map(\.code)) == Set(codes),
      recipe.importedSettings.allSatisfy({ $0.raw.count == 2 })
    else { throw CameraServiceError.unsupportedSettings }
    let entries = Dictionary(
      uniqueKeysWithValues: recipe.importedSettings.map { ($0.code, $0.raw) })
    var canonical = Data("xt5.imported-settings.v1\0".utf8)
    for code in codes {
      canonical.append(contentsOf: [UInt8(truncatingIfNeeded: code), UInt8(code >> 8), 2, 0])
      canonical.append(entries[code]!)
    }
    guard hash(canonical) == recipe.settingsDigest else {
      throw CameraServiceError.unsupportedSettings
    }
    return entries.mapValues { UInt16($0[0]) | UInt16($0[1]) << 8 }
  }
  public init(
    bytes: Data, recipeID: UUID, settingsDigest: String, settings: NormalizedRecipeSettings,
    baselineSHA256: String, candidateSHA256: String
  ) {
    self.bytes = bytes
    self.recipeID = recipeID
    self.settingsDigest = settingsDigest
    self.settings = settings
    self.baselineSHA256 = baselineSHA256
    self.candidateSHA256 = candidateSHA256
  }

}
