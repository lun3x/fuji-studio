import Foundation

/// Native decoding happens once at import. Defaults are never used for a known but unknown selector.
enum StandardRecipeImport {
  static func decode(model: String, properties: [ImportedRecipeProperty], sourceDigest: String)
    -> StandardRecipe
  {
    let camera = RecipeCameraModel(rawValue: model) ?? .xt5
    var recipe = StandardRecipe(camera: camera)
    var evidence = Data(
      (camera == .xt5 ? "xt5.imported-settings.v1\0" : "xe3.imported-settings.v1\0").utf8)
    for property in properties.sorted(by: { $0.code < $1.code }) {
      evidence.append(contentsOf: [
        UInt8(truncatingIfNeeded: property.code), UInt8(property.code >> 8),
        UInt8(truncatingIfNeeded: property.raw.count),
        UInt8(truncatingIfNeeded: property.raw.count >> 8),
      ])
      evidence.append(property.raw)
    }
    guard ResourceChecksum.sha256(evidence) == sourceDigest else {
      recipe.setValue(.unknown("Invalid imported settings"), for: .film)
      return recipe
    }
    let raw = Dictionary(properties.map { ($0.code, $0.raw) }, uniquingKeysWith: { a, _ in a })
    func number(_ code: UInt16, width: Int) -> Int? {
      guard let data = raw[code], data.count == width else { return nil }
      return Int(data[0]) | (width == 2 ? Int(data[1]) << 8 : 0)
    }
    func unknown(_ code: UInt16) -> RecipeSettingValue {
      .unknown(raw[code].map { $0.map { String(format: "%02X", $0) }.joined() } ?? "missing")
    }
    func select<T>(
      _ id: RecipeSettingID, _ code: UInt16, _ table: [UInt16: T],
      _ transform: (T) -> RecipeSettingValue
    ) {
      recipe.setValue(
        number(code, width: camera == .xt5 ? 2 : 1)
          .flatMap { table[UInt16($0)] }.map(transform) ?? unknown(code), for: id)
    }
    func integer(
      _ id: RecipeSettingID, _ code: UInt16, scale: Int = 1,
      offset: Int = 0, signed: Bool = false
    ) {
      guard let n = number(code, width: camera == .xt5 ? 2 : 1) else {
        recipe.setValue(unknown(code), for: id)
        return
      }
      recipe.setValue(
        .integer((signed ? Int(Int16(bitPattern: UInt16(n))) : n) * scale + offset), for: id)
    }
    if camera == .xt5 {
      select(.film, 0xD192, FujiRenderingValues.films, RecipeSettingValue.film)
      select(
        .whiteBalance, 0xD199, FujiRenderingValues.whiteBalances, RecipeSettingValue.whiteBalance)
      select(.grain, 0xD195, XT5GrainValues.readable, RecipeSettingValue.grain)
      for (id, code): (RecipeSettingID, UInt16) in [
        (.colorChrome, 0xD196), (.colorChromeBlue, 0xD197), (.smoothSkin, 0xD198),
      ] { select(id, code, FujiRenderingValues.effects, RecipeSettingValue.effect) }
      select(.noiseReduction, 0xD1A1, FujiRenderingValues.noise, RecipeSettingValue.integer)
      select(
        .dynamicRangePriority, 0xD191,
        [0: RecipeOption.off, 1: .weak, 2: .strong, 0x8000: .auto], RecipeSettingValue.option)
      integer(.dynamicRange, 0xD190)
      integer(.kelvin, 0xD19C)
      for (id, code): (RecipeSettingID, UInt16) in [
        (.whiteBalanceRed, 0xD19A), (.whiteBalanceBlue, 0xD19B), (.highlight, 0xD19D),
        (.shadow, 0xD19E), (.color, 0xD19F), (.sharpness, 0xD1A0), (.clarity, 0xD1A2),
        (.monochromeWarmCool, 0xD193), (.monochromeMagentaGreen, 0xD194),
      ] { integer(id, code, signed: true) }
      select(.lensOptimizer, 0xD1A3, [1: true, 2: false]) { .integer($0 ? 1 : 0) }
      select(.colorSpace, 0xD1A4, [1: RecipeOption.sRGB, 2: .adobeRGB], RecipeSettingValue.option)
      // Slot/live image-quality correspondence is documented in the native mapping audit.
      select(
        .imageQuality, 0xD18F,
        [1: RecipeOption.raw, 2: .fine, 3: .normal, 4: .fineRAW, 5: .normalRAW],
        RecipeSettingValue.option)
      let dimensions: [Int: (RecipeOption, RecipeOption)] = [
        1: (.small, .ratio3x2), 2: (.small, .ratio16x9), 3: (.small, .ratio1x1),
        4: (.medium, .ratio3x2), 5: (.medium, .ratio16x9), 6: (.medium, .ratio1x1),
        7: (.large, .ratio3x2), 8: (.large, .ratio16x9), 9: (.large, .ratio1x1),
        10: (.small, .ratio4x3), 12: (.small, .ratio5x4), 14: (.large, .ratio4x3),
        16: (.large, .ratio5x4), 18: (.medium, .ratio4x3), 20: (.medium, .ratio5x4),
      ]
      if let n = number(0xD18E, width: 2), let size = dimensions[n] {
        recipe.setValue(.option(size.0), for: .imageSize)
        recipe.setValue(.option(size.1), for: .aspectRatio)
      } else {
        recipe.setValue(unknown(0xD18E), for: .imageSize)
        recipe.setValue(unknown(0xD18E), for: .aspectRatio)
      }
    } else {
      func widen<T>(_ table: [UInt8: T]) -> [UInt16: T] {
        Dictionary(uniqueKeysWithValues: table.map { (UInt16($0.key), $0.value) })
      }
      select(.film, 1, widen(XE3NativeRecipeFields.films), RecipeSettingValue.film)
      select(
        .whiteBalance, 4, widen(XE3NativeRecipeFields.whiteBalances),
        RecipeSettingValue.whiteBalance)
      select(.grain, 3, widen(XE3NativeRecipeFields.grains)) {
        .grain(.init(strength: $0, size: nil))
      }
      select(.dynamicRange, 2, [0: 0, 1: 100, 2: 200, 3: 400], RecipeSettingValue.integer)
      integer(.whiteBalanceRed, 5, scale: -1, offset: 9)
      integer(.whiteBalanceBlue, 6, scale: -1, offset: 9)
      select(
        .kelvin, 7,
        Dictionary(
          uniqueKeysWithValues: XE3NativeRecipeFields.kelvin.enumerated()
            .map { (UInt16($0.offset), $0.element) }), RecipeSettingValue.integer)
      integer(.highlight, 8, scale: -10, offset: 40)
      integer(.shadow, 9, scale: -10, offset: 40)
      select(.color, 10, widen(XE3NativeRecipeFields.colors)) { .integer($0 * 10) }
      integer(.sharpness, 11, scale: -10, offset: 40)
      integer(.noiseReduction, 12, offset: -4)
      recipe.setValue(.unknown("Not read from camera"), for: .iso)
    }
    return recipe
  }
}
