import Foundation

public enum RecipeCameraModel: String, Codable, CaseIterable, Sendable, Hashable {
  case xt5 = "X-T5"
  case xe3 = "X-E3"
  public var firmware: String { self == .xt5 ? "4.31" : "1.30" }
  public var capability: String { self == .xt5 ? "X-T5_0200" : XE3Support.identifier }
  public var supportVersion: String {
    self == .xt5 ? XT5WorkingProfile.supportVersion : XE3Support.conversionVersion
  }
  public func matches(_ context: CameraExecutionContext) -> Bool {
    context.model == rawValue && context.firmware == firmware
      && context.capability == capability && context.supportVersion == supportVersion
  }
}

/// Shared selector identities, independent of native wire values.
public enum RecipeOption: String, Codable, CaseIterable, Sendable, Hashable {
  case off, weak, strong, auto, small, large, medium
  case sRGB, adobeRGB, fine, normal, fineRAW, normalRAW, raw
  case uncompressed, losslessCompressed, compressed, jpeg, heif
  case ratio3x2, ratio4x3, ratio16x9, ratio5x4, ratio1x1
  case auto1, auto2, auto3
  public var label: String {
    switch self {
    case .sRGB: "sRGB"
    case .adobeRGB: "Adobe RGB"
    case .fineRAW: "Fine+RAW"
    case .normalRAW: "Normal+RAW"
    case .raw: "RAW"
    case .losslessCompressed: "Lossless compressed"
    case .jpeg: "JPEG"
    case .heif: "HEIF"
    case .ratio3x2: "3:2"
    case .ratio4x3: "4:3"
    case .ratio16x9: "16:9"
    case .ratio5x4: "5:4"
    case .ratio1x1: "1:1"
    case .auto1: "Auto 1"
    case .auto2: "Auto 2"
    case .auto3: "Auto 3"
    default: rawValue.capitalized
    }
  }
}

/// Complete persisted request. Camera changes never coerce, remove, or default a value.
public struct StandardRecipe: Codable, Sendable, Equatable {
  public var camera: RecipeCameraModel
  public private(set) var values: [RecipeSettingID: RecipeSettingValue]

  public init(camera: RecipeCameraModel, values: [RecipeSettingID: RecipeSettingValue] = [:]) {
    self.camera = camera
    self.values = StandardRecipeCatalog.defaults
    for (id, value) in values { setValue(value, for: id) }
  }
  public func value(for id: RecipeSettingID) -> RecipeSettingValue { values[id]! }
  public mutating func setValue(_ value: RecipeSettingValue, for id: RecipeSettingID) {
    if id == .grain, case .grain(let grain) = value {
      values[id] = .grain(.init(strength: grain.strength, size: nil))
      if let size = grain.size { values[.grainSize] = .option(size == .small ? .small : .large) }
    } else {
      values[id] = value
    }
  }
  public func isAvailable(_ id: RecipeSettingID) -> Bool {
    guard StandardRecipeCatalog.capability(for: id, camera: camera).support == .supported else {
      return false
    }
    switch id {
    case .monochromeWarmCool, .monochromeMagentaGreen:
      guard case .film(let film) = value(for: .film) else { return false }
      return film.supportsMonochromaticColor
    case .grainSize:
      guard case .grain(let grain) = value(for: .grain) else { return false }
      return grain.strength != .off
    case .kelvin: return value(for: .whiteBalance) == .whiteBalance(.temperature)
    case .dynamicRange, .highlight, .shadow:
      return camera != .xt5 || value(for: .dynamicRangePriority) == .option(.off)
    case .clarity: return camera != .xt5 || value(for: .outputFormat) != .option(.heif)
    default: return true
    }
  }
  public func accepts(_ value: RecipeSettingValue, for id: RecipeSettingID) -> Bool {
    if id == .colorSpace, camera == .xt5, self.value(for: .outputFormat) == .option(.heif) {
      return value == .option(.sRGB)
    }
    return StandardRecipeCatalog.capability(for: id, camera: camera).accepts(
      value, rendering: false)
  }
  public var invalidSettings: [RecipeSettingID] {
    RecipeSettingID.allCases.filter { isAvailable($0) && !accepts(value(for: $0), for: $0) }
  }

  private enum CodingKeys: CodingKey { case camera, values }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    camera = try c.decode(RecipeCameraModel.self, forKey: .camera)
    values = try c.decode([RecipeSettingID: RecipeSettingValue].self, forKey: .values)
    guard Set(values.keys) == Set(RecipeSettingID.allCases) else {
      throw DecodingError.dataCorruptedError(
        forKey: .values, in: c,
        debugDescription: "A standard recipe must contain every setting")
    }
  }
}

extension FilmSimulation {
  public var supportsMonochromaticColor: Bool {
    [
      .monochrome, .monochromeYellow, .monochromeRed, .monochromeGreen,
      .acros, .acrosYellow, .acrosRed, .acrosGreen,
    ].contains(self)
  }
}
