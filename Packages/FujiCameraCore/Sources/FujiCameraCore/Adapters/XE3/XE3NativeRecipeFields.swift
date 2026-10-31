import Foundation

enum XE3NativeRecipeFields {
  // Model-scoped native backup fields, not invented X-T5 PTP property addresses.
  static let required = Set(UInt16(1)...13)
  static let films: [UInt8: FilmSimulation] = [
    0: .provia, 1: .astia, 3: .velvia, 5: .sepia, 7: .monochrome, 8: .monochromeRed,
    9: .monochromeYellow, 10: .monochromeGreen, 11: .proNegStd, 12: .proNegHi, 13: .classicChrome,
    14: .acros, 15: .acrosRed, 16: .acrosYellow, 17: .acrosGreen,
  ]
  static let colors: [UInt8: Int] = [3: 4, 4: 3, 5: 2, 6: 1, 0: 0, 8: -1, 7: -2, 9: -3, 10: -4]
  static let whiteBalances: [UInt8: WhiteBalanceMode] = [
    0: .auto, 1: .daylight, 2: .shade, 3: .fluorescent1, 4: .fluorescent2, 5: .fluorescent3,
    6: .incandescent, 7: .underwater, 8: .temperature,
  ]
  static let grains: [UInt8: GrainStrength] = [0: .strong, 1: .weak, 2: .off]
  static let kelvin = [
    10000, 9100, 8300, 7700, 7100, 6700, 6300, 5900, 5600, 5300, 5000, 4800, 4500, 4300, 4200, 4000,
    3800, 3700, 3600, 3400, 3300, 3200, 3100, 3000, 2950, 2850, 2800, 2700, 2650, 2550, 2500,
  ]
  // Each preset pair was verified by controlled backup changes and restoration.
  // Custom measured-WB dependencies remain unvalidated.
  static let verifiedShiftOffsets: Set<Int> = [433, 441, 443, 445, 447, 449, 451, 453, 455]
  static let shiftOffsets: [UInt8: Int] = [
    0: 433, 1: 443, 2: 445, 3: 447, 4: 449, 5: 451, 6: 453, 7: 455, 8: 441,
  ]
  static func digest(_ fields: [UInt16: Data]) -> String {
    var bytes = Data("xe3.imported-settings.v1\0".utf8)
    for code in fields.keys.sorted() {
      let value = fields[code]!
      bytes.append(contentsOf: [
        UInt8(truncatingIfNeeded: code), UInt8(code >> 8), UInt8(truncatingIfNeeded: value.count),
        UInt8(value.count >> 8),
      ])
      bytes.append(value)
    }
    return ResourceChecksum.sha256(bytes)
  }
  static func properties(_ snapshot: RecipeSnapshot) throws -> [UInt16: Data] {
    guard snapshot.cameraContext.model == "X-E3", snapshot.cameraContext.firmware == "1.30",
      snapshot.cameraContext.capability == XE3Support.identifier
    else { throw CameraServiceError.unsupportedContext }
    guard snapshot.importedSettings.count <= 64,
      Set(snapshot.importedSettings.map(\.code)).count == snapshot.importedSettings.count,
      snapshot.importedSettings.allSatisfy({ $0.raw.count <= 1024 })
    else { throw CameraServiceError.unsupportedSettings }
    let fields = Dictionary(
      uniqueKeysWithValues: snapshot.importedSettings.map { ($0.code, $0.raw) })
    let knownWB = fields[4]?.count == 1 && whiteBalances[fields[4]![0]] != nil
    let ownFields = required.subtracting([5, 6, 13])
    guard ownFields.isSubset(of: Set(fields.keys)),
      ownFields.allSatisfy({ fields[$0]?.count == 1 }),
      digest(fields) == snapshot.sourceSettingsDigest
    else { throw CameraServiceError.unsupportedSettings }
    if knownWB {
      guard fields[5]?.count == 1, fields[6]?.count == 1, fields[13]?.count == 2 else {
        throw CameraServiceError.unsupportedSettings
      }
    } else {
      guard fields[14]?.count == 24, fields[5] == nil, fields[6] == nil, fields[13] == nil else {
        throw CameraServiceError.unsupportedSettings
      }
    }
    return fields
  }
}
public enum XE3RecipeCodec {
  public static func recipe(
    slot: Int, nameData: Data, properties: [UInt16: Data], context: RecipeCameraContext,
    importedAt: Date
  ) throws -> RecipeSnapshot {
    guard (1...7).contains(slot), nameData.count <= 16, properties.count <= 64,
      properties.values.allSatisfy({ $0.count <= 1024 })
    else { throw RecipeImportError.invalidSlot }
    let name = String(decoding: nameData.prefix { $0 != 0 }, as: UTF8.self)
    let snapshot = RecipeSnapshot(
      id: UUID(), slot: slot, name: name, importedName: nameData,
      importedSettings: properties.keys.sorted().map { .init(code: $0, raw: properties[$0]!) },
      settingsDigest: XE3NativeRecipeFields.digest(properties), cameraContext: context,
      importedAt: importedAt, renderingIssues: [])
    _ = try XE3NativeRecipeFields.properties(snapshot)
    return snapshot.recordingIssues(assess(snapshot).issues)
  }
  public static func decode(_ snapshot: RecipeSnapshot) throws -> RecipeSettings {
    let p = try XE3NativeRecipeFields.properties(snapshot)
    func byte(_ id: UInt16) -> UInt8 { p[id]![0] }
    guard let film = XE3NativeRecipeFields.films[byte(1)],
      let grain = XE3NativeRecipeFields.grains[byte(3)],
      let wb = XE3NativeRecipeFields.whiteBalances[byte(4)],
      let color = XE3NativeRecipeFields.colors[byte(10)], byte(2) <= 3, byte(5) <= 18,
      byte(6) <= 18, byte(8) <= 6, byte(9) <= 6, byte(11) <= 8, byte(12) <= 8
    else { throw CameraServiceError.unsupportedSettings }
    let temperature: Int?
    if wb == .temperature {
      guard Int(byte(7)) < XE3NativeRecipeFields.kelvin.count else {
        throw CameraServiceError.unsupportedSettings
      }
      temperature = XE3NativeRecipeFields.kelvin[Int(byte(7))]
    } else {
      temperature = nil
    }
    return RecipeSettings(
      film: film, grain: .init(strength: grain, size: nil),
      dynamicRange: [0, 100, 200, 400][Int(byte(2))], whiteBalance: wb,
      whiteBalanceRed: 9 - Int(byte(5)), whiteBalanceBlue: 9 - Int(byte(6)), kelvin: temperature,
      highlightTenths: (4 - Int(byte(8))) * 10, shadowTenths: (4 - Int(byte(9))) * 10,
      colorTenths: color * 10, sharpnessTenths: (4 - Int(byte(11))) * 10,
      noiseReduction: Int(byte(12)) - 4)
  }
  public static func assess(_ snapshot: RecipeSnapshot) -> RecipeAssessment {
    do {
      let p = try XE3NativeRecipeFields.properties(snapshot)
      let settings = try decode(snapshot)
      var issues = Set(p.keys).subtracting(XE3NativeRecipeFields.required).sorted().map(
        RecipeRenderingIssue.unmappedProperty)
      let offset = Int(p[13]![0]) | Int(p[13]![1]) << 8
      if !XE3NativeRecipeFields.verifiedShiftOffsets.contains(offset)
        || XE3NativeRecipeFields.shiftOffsets[p[4]![0]] != offset
      {
        issues.append(.unvalidatedDependency("shared white-balance shift"))
      }
      do { try XE3Capabilities.validate(settings) } catch {
        issues.append(.unsupportedMeasuredDomain)
      }
      return .init(settings: settings, issues: issues)
    } catch CameraServiceError.unsupportedContext {
      return .init(settings: nil, issues: [.unsupportedCameraContext])
    } catch { return .init(settings: nil, issues: [.unsupportedMeasuredDomain]) }
  }
  public static func encodeEditedRecipe(
    _ settings: RecipeSettings, preserving snapshot: RecipeSnapshot
  ) throws -> RecipeSnapshot {
    try XE3Capabilities.validate(settings)
    var p = try XE3NativeRecipeFields.properties(snapshot)
    func key<T: Equatable>(_ table: [UInt8: T], _ value: T) throws -> UInt8 {
      guard let key = table.first(where: { $0.value == value })?.key else {
        throw CameraServiceError.unsupportedSettings
      }
      return key
    }
    func put(_ value: UInt8, _ id: UInt16) { p[id] = Data([value]) }
    put(try key(XE3NativeRecipeFields.films, settings.film), 1)
    put(UInt8([100: 1, 200: 2, 400: 3][settings.dynamicRange]!), 2)
    put(try key(XE3NativeRecipeFields.grains, settings.grain.strength), 3)
    put(try key(XE3NativeRecipeFields.whiteBalances, settings.whiteBalance), 4)
    let offset = XE3NativeRecipeFields.shiftOffsets[p[4]![0]]!
    p[13] = Data([UInt8(truncatingIfNeeded: offset), UInt8(offset >> 8)])
    put(UInt8(9 - settings.whiteBalanceRed), 5)
    put(UInt8(9 - settings.whiteBalanceBlue), 6)
    if settings.whiteBalance == .temperature, let kelvin = settings.kelvin {
      put(UInt8(XE3NativeRecipeFields.kelvin.firstIndex(of: kelvin)!), 7)
    }
    put(UInt8(4 - settings.highlightTenths / 10), 8)
    put(UInt8(4 - settings.shadowTenths / 10), 9)
    put(try key(XE3NativeRecipeFields.colors, settings.colorTenths / 10), 10)
    put(UInt8(4 - settings.sharpnessTenths / 10), 11)
    put(UInt8(settings.noiseReduction + 4), 12)
    let result = try recipe(
      slot: snapshot.slot, nameData: snapshot.importedName, properties: p,
      context: snapshot.cameraContext, importedAt: snapshot.importedAt)
    return RecipeSnapshot(
      id: result.id, slot: snapshot.slot, name: snapshot.name, importedName: snapshot.importedName,
      importedSettings: result.importedSettings, settingsDigest: result.sourceSettingsDigest,
      cameraContext: snapshot.cameraContext, importedAt: snapshot.importedAt,
      renderingIssues: result.renderingIssues, copiedFromRecipeID: snapshot.copiedFromRecipeID)
  }
}
extension RecipeSnapshot {
  func recordingIssues(_ issues: [RecipeRenderingIssue]) -> RecipeSnapshot {
    .init(
      id: id, slot: slot, name: name, importedName: importedName,
      importedSettings: importedSettings, settingsDigest: sourceSettingsDigest,
      cameraContext: cameraContext, importedAt: importedAt, renderingIssues: issues,
      copiedFromRecipeID: copiedFromRecipeID, standardRecipe: standardRecipe)
  }
}
