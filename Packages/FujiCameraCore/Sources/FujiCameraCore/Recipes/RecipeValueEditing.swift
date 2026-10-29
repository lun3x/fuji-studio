import Foundation

extension RecipeCodecRegistry {
  /// Partial projection keeps unknown imported values passive while other known fields
  /// remain editable. No UI needs model-specific field addresses or integer encodings.
  public func editableValues(_ snapshot: RecipeSnapshot) throws -> [RecipeSettingID:
    RecipeSettingValue]
  {
    _ = try capabilities(for: snapshot.cameraContext)
    let raw = try nativeFields(snapshot)
    return SemanticNativeField.fields(model: snapshot.cameraContext.model).compactMapValues {
      field in
      raw[field.code].flatMap(field.decode)
    }
  }
  public func encodeEditedValues(
    _ changes: [RecipeSettingID: RecipeSettingValue], preserving snapshot: RecipeSnapshot
  ) throws -> RecipeSnapshot {
    let capabilities = try capabilities(for: snapshot.cameraContext)
    var raw = try nativeFields(snapshot)
    let fields = SemanticNativeField.fields(model: snapshot.cameraContext.model)
    guard !changes.isEmpty else { return snapshot }
    for (id, requested) in changes {
      let value =
        snapshot.cameraContext.model == "X-T5" ? XT5GrainValues.canonical(requested) : requested
      guard capabilities.settings[id]?.accepts(value, rendering: false) == true,
        let field = fields[id], let encoded = field.encode(value)
      else { throw CameraServiceError.unsupportedSettings }
      raw[field.code] = encoded
    }
    let result: RecipeSnapshot
    if snapshot.cameraContext.model == "X-E3" {
      if changes[.whiteBalance] != nil, let wb = raw[4]?.first,
        let offset = XE3NativeRecipeFields.shiftOffsets[wb]
      {
        raw[13] = Data([UInt8(truncatingIfNeeded: offset), UInt8(offset >> 8)])
      }
      result = try XE3RecipeCodec.recipe(
        slot: snapshot.slot, nameData: snapshot.importedName, properties: raw,
        context: snapshot.cameraContext, importedAt: snapshot.importedAt)
    } else {
      result = try XT5RecipeCodec.recipe(
        slot: snapshot.slot, nameData: snapshot.importedName, properties: raw,
        context: snapshot.cameraContext, importedAt: snapshot.importedAt)
    }
    return .init(
      id: result.id, slot: snapshot.slot, name: snapshot.name, importedName: snapshot.importedName,
      importedSettings: result.importedSettings, settingsDigest: result.settingsDigest,
      cameraContext: snapshot.cameraContext,
      importedAt: snapshot.importedAt, renderingIssues: assess(result).issues,
      copiedFromRecipeID: snapshot.copiedFromRecipeID)
  }
  private func nativeFields(_ snapshot: RecipeSnapshot) throws -> [UInt16: Data] {
    if snapshot.cameraContext.model == "X-E3" {
      return try XE3NativeRecipeFields.properties(snapshot)
    }
    _ = try XT5WorkingProfile.properties(snapshot)
    return Dictionary(uniqueKeysWithValues: snapshot.importedSettings.map { ($0.code, $0.raw) })
  }
}

private struct SemanticNativeField {
  enum Encoding {
    case choices([UInt16: RecipeSettingValue])
    case integer(scale: Int, offset: Int, signed: Bool)
    case xt5Grain
  }
  let code: UInt16, width: Int, encoding: Encoding
  func decode(_ data: Data) -> RecipeSettingValue? {
    guard data.count == width else { return nil }
    let raw = UInt16(data[0]) | (width == 2 ? UInt16(data[1]) << 8 : 0)
    switch encoding {
    case .choices(let values): return values[raw]
    case .xt5Grain: return XT5GrainValues.readable[raw].map(RecipeSettingValue.grain)
    case .integer(let scale, let offset, let signed):
      return .integer((signed ? Int(Int16(bitPattern: raw)) : Int(raw)) * scale + offset)
    }
  }
  func encode(_ value: RecipeSettingValue) -> Data? {
    let raw: UInt16
    switch encoding {
    case .xt5Grain:
      guard case .grain(let grain) = value, let encoded = XT5GrainValues.encode(grain) else {
        return nil
      }
      raw = encoded
    case .choices(let values):
      guard let key = values.first(where: { $0.value == value })?.key else { return nil }
      raw = key
    case .integer(let scale, let offset, let signed):
      guard case .integer(let value) = value, (value - offset) % scale == 0 else { return nil }
      let number = (value - offset) / scale
      if signed {
        guard let signed = Int16(exactly: number) else { return nil }
        raw = UInt16(bitPattern: signed)
      } else {
        guard let unsigned = UInt16(exactly: number) else { return nil }
        raw = unsigned
      }
    }
    if width == 1 {
      guard raw <= 255 else { return nil }
      return Data([UInt8(raw)])
    }
    return Data([UInt8(truncatingIfNeeded: raw), UInt8(raw >> 8)])
  }
  static func fields(model: String) -> [RecipeSettingID: Self] {
    var result: [RecipeSettingID: Self] = [:]
    let width = model == "X-E3" ? 1 : 2
    func choices(_ id: RecipeSettingID, _ code: UInt16, _ values: [UInt16: RecipeSettingValue]) {
      result[id] = Self(code: code, width: width, encoding: .choices(values))
    }
    func integer(
      _ id: RecipeSettingID, _ code: UInt16, _ scale: Int = 1, _ offset: Int = 0,
      _ signed: Bool = false
    ) {
      result[id] = Self(
        code: code, width: width, encoding: .integer(scale: scale, offset: offset, signed: signed))
    }
    if model == "X-E3" {
      func widen<T>(_ values: [UInt8: T], _ transform: (T) -> RecipeSettingValue) -> [UInt16:
        RecipeSettingValue]
      {
        Dictionary(uniqueKeysWithValues: values.map { (UInt16($0.key), transform($0.value)) })
      }
      choices(.film, 1, widen(XE3NativeRecipeFields.films, RecipeSettingValue.film))
      choices(
        .grain, 3, widen(XE3NativeRecipeFields.grains) { .grain(.init(strength: $0, size: nil)) })
      choices(
        .dynamicRange, 2, [0: .integer(0), 1: .integer(100), 2: .integer(200), 3: .integer(400)])
      choices(
        .whiteBalance, 4,
        widen(XE3NativeRecipeFields.whiteBalances, RecipeSettingValue.whiteBalance))
      integer(.whiteBalanceRed, 5, -1, 9)
      integer(.whiteBalanceBlue, 6, -1, 9)
      choices(
        .kelvin, 7,
        Dictionary(
          uniqueKeysWithValues: XE3NativeRecipeFields.kelvin.enumerated().map {
            (UInt16($0.offset), .integer($0.element))
          }))
      integer(.highlight, 8, -10, 40)
      integer(.shadow, 9, -10, 40)
      choices(.color, 10, widen(XE3NativeRecipeFields.colors) { .integer($0 * 10) })
      integer(.sharpness, 11, -10, 40)
      integer(.noiseReduction, 12, 1, -4)
    } else {
      choices(.film, 0xD192, FujiRenderingValues.films.mapValues(RecipeSettingValue.film))
      choices(
        .whiteBalance, 0xD199,
        FujiRenderingValues.whiteBalances.mapValues(RecipeSettingValue.whiteBalance))
      result[.grain] = Self(code: 0xD195, width: width, encoding: .xt5Grain)
      choices(
        .colorChrome, 0xD196, FujiRenderingValues.effects.mapValues(RecipeSettingValue.effect))
      choices(
        .colorChromeBlue, 0xD197, FujiRenderingValues.effects.mapValues(RecipeSettingValue.effect))
      choices(
        .noiseReduction, 0xD1A1, FujiRenderingValues.noise.mapValues(RecipeSettingValue.integer))
      integer(.dynamicRange, 0xD190)
      integer(.kelvin, 0xD19C)
      for (id, code): (RecipeSettingID, UInt16) in [
        (.whiteBalanceRed, 0xD19A), (.whiteBalanceBlue, 0xD19B), (.highlight, 0xD19D),
        (.shadow, 0xD19E), (.color, 0xD19F), (.sharpness, 0xD1A0), (.clarity, 0xD1A2),
      ] { integer(id, code, 1, 0, true) }
    }
    return result
  }
}
