import Foundation

// Native encodings belong to the Fuji adapter family, never editor identities.
enum FujiRenderingValues {
  // Selector provenance and the separate measured conversion domain are recorded
  // in docs/validation/recipe-option-values.md. These are not EXIF tag values.
  static let films: [UInt16: FilmSimulation] = [
    1: .provia, 2: .velvia, 3: .astia, 4: .proNegHi, 5: .proNegStd, 6: .monochrome,
    7: .monochromeYellow, 8: .monochromeRed, 9: .monochromeGreen, 10: .sepia, 11: .classicChrome,
    12: .acros, 13: .acrosYellow, 14: .acrosRed, 15: .acrosGreen,
    16: .eterna, 17: .classicNeg, 18: .eternaBleachBypass, 19: .nostalgicNeg, 20: .realaAce,
  ]
  static let whiteBalances: [UInt16: WhiteBalanceMode] = [
    2: .auto, 4: .daylight, 0x8006: .shade, 0x8001: .fluorescent1, 0x8002: .fluorescent2,
    0x8003: .fluorescent3, 6: .incandescent, 8: .underwater, 0x8007: .temperature,
    0x8020: .autoWhitePriority, 0x8021: .autoAmbiencePriority,
    0x8008: .custom1, 0x8009: .custom2, 0x800a: .custom3,
  ]
  static let effects: [UInt16: EffectStrength] = [1: .off, 2: .weak, 3: .strong]
  static let noise: [UInt16: Int] = [
    0x8000: -4, 0x7000: -3, 0x4000: -2, 0x3000: -1, 0x2000: 0, 0x1000: 1, 0: 2, 0x6000: 3,
    0x5000: 4,
  ]
}
enum XT5RecipeSettingsCodec {
  static func decode(_ snapshot: RecipeSnapshot) throws -> RecipeSettings {
    let p = try XT5WorkingProfile.properties(snapshot)
    func v(_ code: UInt16) -> UInt16 { p[code]! }
    func s(_ code: UInt16) -> Int { Int(Int16(bitPattern: v(code))) }
    let grains: [UInt16: GrainSettings] = [
      1: .init(strength: .weak, size: .small), 2: .init(strength: .weak, size: .large),
      3: .init(strength: .strong, size: .small), 4: .init(strength: .strong, size: .large),
      6: .init(strength: .off, size: .small), 7: .init(strength: .off, size: .large),
    ]
    guard let film = FujiRenderingValues.films[v(0xD192)],
      let wb = FujiRenderingValues.whiteBalances[v(0xD199)], let grain = grains[v(0xD195)],
      let nr = FujiRenderingValues.noise[v(0xD1A1)],
      let chrome = FujiRenderingValues.effects[v(0xD196)],
      let blue = FujiRenderingValues.effects[v(0xD197)]
    else { throw CameraServiceError.unsupportedSettings }
    return RecipeSettings(
      film: film, grain: grain, dynamicRange: Int(v(0xD190)), whiteBalance: wb,
      whiteBalanceRed: s(0xD19A), whiteBalanceBlue: s(0xD19B), kelvin: Int(v(0xD19C)),
      highlightTenths: s(0xD19D), shadowTenths: s(0xD19E), colorTenths: s(0xD19F),
      sharpnessTenths: s(0xD1A0), noiseReduction: nr, colorChrome: chrome, colorChromeBlue: blue,
      clarityTenths: s(0xD1A2), lensOptimizerRequested: true)
  }
  static func encode(_ settings: RecipeSettings, preserving original: RecipeSnapshot) throws
    -> RecipeSnapshot
  {
    let capability = RecipeCodecRegistry.xt5Capabilities
    for (id, value) in settings.values {
      guard capability.settings[id]?.accepts(value, rendering: false) == true else {
        throw CameraServiceError.unsupportedSettings
      }
    }
    let p = try XT5WorkingProfile.properties(original)
    func key<T: Equatable>(_ dictionary: [UInt16: T], _ value: T) throws -> UInt16 {
      guard let key = dictionary.first(where: { $0.value == value })?.key else {
        throw CameraServiceError.unsupportedSettings
      }
      return key
    }
    func signed(_ n: Int) throws -> UInt16 {
      guard let n = Int16(exactly: n) else { throw CameraServiceError.unsupportedSettings }
      return UInt16(bitPattern: n)
    }
    let grainCodes: [GrainSettings: UInt16] = [
      .init(strength: .off, size: .small): 6, .init(strength: .off, size: .large): 7,
      .init(strength: .weak, size: .small): 1, .init(strength: .weak, size: .large): 2,
      .init(strength: .strong, size: .small): 3, .init(strength: .strong, size: .large): 4,
    ]
    guard let grain = grainCodes[settings.grain], let kelvin = settings.kelvin,
      let chrome = settings.colorChrome, let blue = settings.colorChromeBlue,
      let clarity = settings.clarityTenths
    else { throw CameraServiceError.unsupportedSettings }
    var updated = p
    updated[0xD192] = try key(FujiRenderingValues.films, settings.film)
    updated[0xD190] = UInt16(settings.dynamicRange)
    updated[0xD195] = grain
    updated[0xD196] = try key(FujiRenderingValues.effects, chrome)
    updated[0xD197] = try key(FujiRenderingValues.effects, blue)
    updated[0xD199] = try key(FujiRenderingValues.whiteBalances, settings.whiteBalance)
    for (code, value): (UInt16, Int) in [
      (0xD19A, settings.whiteBalanceRed), (0xD19B, settings.whiteBalanceBlue),
      (0xD19D, settings.highlightTenths), (0xD19E, settings.shadowTenths),
      (0xD19F, settings.colorTenths), (0xD1A0, settings.sharpnessTenths), (0xD1A2, clarity),
    ] { updated[code] = try signed(value) }
    updated[0xD19C] = UInt16(kelvin)
    updated[0xD1A1] = try key(FujiRenderingValues.noise, settings.noiseReduction)
    let result = try XT5RecipeCodec.recipe(
      slot: original.slot, nameData: original.importedName,
      properties: updated.mapValues { Data([UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)]) },
      context: original.cameraContext, importedAt: original.importedAt)
    return RecipeSnapshot(
      id: result.id, slot: original.slot, name: original.name, importedName: original.importedName,
      importedSettings: result.importedSettings, settingsDigest: result.settingsDigest,
      cameraContext: original.cameraContext, importedAt: original.importedAt,
      renderingIssues: result.renderingIssues, copiedFromRecipeID: original.copiedFromRecipeID)
  }
}
