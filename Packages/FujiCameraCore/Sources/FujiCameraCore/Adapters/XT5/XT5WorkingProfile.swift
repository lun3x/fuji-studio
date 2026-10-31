import CryptoKit
import Foundation

/// Measured frame structure with replaceable starting settings. Always patches fresh input.
public struct XT5WorkingProfile: Sendable {
  public static let supportVersion = "xt5-4.31-0200-structured-frame-v6-standard-recipes"
  public static let writableOffsets = [
    533, 541, 545, 549, 553, 557, 561, 565, 569, 573, 577, 581, 585, 589, 593, 609, 617,
  ]
  public let bytes: Data
  public let recipeID: UUID
  public let settingsDigest: String
  public let settings: RecipeSettings
  public let effectiveDynamicRange: Int
  public var effectiveLensOptimizer: Bool { bytes[593] == 1 }
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
  public static func normalize(_ recipe: RecipeSnapshot) throws -> RecipeSettings {
    guard recipe.targetCamera == .xt5 else { throw CameraServiceError.unsupportedContext }
    do { return try RecipeCodecRegistry().applicationSettings(recipe) }
    catch { throw CameraServiceError.unsupportedSettings }
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
      let offset = 513 + i * 4
      // These complete words are replaced below; their starting values cannot reach the camera.
      if writableOffsets.contains(offset) { continue }
      guard baseline.subdata(in: offset..<offset + 4) == word(UInt32(bitPattern: v)) else {
        throw CameraServiceError.unsupportedProfile
      }
    }
    let p = try nativeProfileValues(settings)
    var output = baseline
    let rules: [(Int, UInt16, Bool)] = [
      (541, 0xD192, false), (549, 0xD196, false), (557, 0xD199, false),
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
    let effectiveDynamicRange = metadata.effectiveDynamicRange(for: settings.dynamicRange)
    output.replaceSubrange(533..<537, with: word(UInt32(effectiveDynamicRange)))
    output.replaceSubrange(545..<549, with: word(settings.grain.strength == .strong ? 3 : 1))
    output.replaceSubrange(553..<557, with: word(2))
    let lensOptimizer = metadata.effectiveLensOptimizer(for: settings.lensOptimizerRequested ?? true)
    output.replaceSubrange(593..<597, with: word(lensOptimizer ? 1 : 2))
    return Self(
      bytes: output, recipeID: recipe.id, settingsDigest: recipe.settingsDigest, settings: settings,
      effectiveDynamicRange: effectiveDynamicRange,
      baselineSHA256: hash(baseline), candidateSHA256: hash(output))
  }
  public func effective(lensOptimizer: Bool) -> EffectiveRecipeReport {
    EffectiveRecipeReport(
      supportVersion: Self.supportVersion, requested: settings,
      dormantGrainSizeNotSerialized: settings.grain.strength != .strong,
      inactiveKelvinPreserved: settings.whiteBalance != .temperature,
      lensOptimizerRequested: settings.lensOptimizerRequested ?? true,
      lensOptimizerEffective: lensOptimizer,
      lensOptimizerAdjusted: lensOptimizer != (settings.lensOptimizerRequested ?? true),
      evidence:
        "Exact profile readback; JPEG Fuji quality/context and LMO metadata. Opaque tuple accepted only within observed frame support.",
      dynamicRangeEffective: effectiveDynamicRange
    )
  }
  public static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  private static func word(_ value: UInt32) -> Data {
    Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
  }
  static func properties(_ recipe: RecipeSnapshot) throws -> [UInt16: UInt16] {
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
    guard hash(canonical) == recipe.sourceSettingsDigest else {
      throw CameraServiceError.unsupportedSettings
    }
    return entries.mapValues { UInt16($0[0]) | UInt16($0[1]) << 8 }
  }
  private static func nativeProfileValues(_ settings: RecipeSettings) throws -> [UInt16: UInt16] {
    func key<T: Equatable>(_ table: [UInt16: T], _ value: T) throws -> UInt16 {
      guard let key = table.first(where: { $0.value == value })?.key else {
        throw CameraServiceError.unsupportedSettings
      }
      return key
    }
    var result: [UInt16: UInt16] = [
      0xD192: try key(FujiRenderingValues.films, settings.film),
      0xD196: try key(FujiRenderingValues.effects, settings.colorChrome ?? .off),
      0xD197: try key(FujiRenderingValues.effects, settings.colorChromeBlue ?? .off),
      0xD199: try key(FujiRenderingValues.whiteBalances, settings.whiteBalance),
      0xD1A1: try key(FujiRenderingValues.noise, settings.noiseReduction),
      0xD19C: UInt16(settings.kelvin ?? 5000),
    ]
    for (code, value): (UInt16, Int) in [
      (0xD19A, settings.whiteBalanceRed), (0xD19B, settings.whiteBalanceBlue),
      (0xD19D, settings.highlightTenths), (0xD19E, settings.shadowTenths),
      (0xD19F, settings.colorTenths), (0xD1A0, settings.sharpnessTenths),
      (0xD1A2, settings.clarityTenths ?? 0),
    ] { result[code] = UInt16(bitPattern: Int16(value)) }
    return result
  }
  public init(
    bytes: Data, recipeID: UUID, settingsDigest: String, settings: RecipeSettings,
    effectiveDynamicRange: Int,
    baselineSHA256: String, candidateSHA256: String
  ) {
    self.bytes = bytes
    self.recipeID = recipeID
    self.settingsDigest = settingsDigest
    self.settings = settings
    self.effectiveDynamicRange = effectiveDynamicRange
    self.baselineSHA256 = baselineSHA256
    self.candidateSHA256 = candidateSHA256
  }

}
