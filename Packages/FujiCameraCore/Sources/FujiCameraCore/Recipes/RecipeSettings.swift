import Foundation

public enum FilmSimulation: String, CaseIterable, Codable, Sendable, Hashable {
  case provia, velvia, astia, proNegHi, proNegStd, monochrome, monochromeYellow, monochromeRed,
    monochromeGreen, sepia, classicChrome, acros, acrosYellow, acrosRed, acrosGreen,
    eterna, classicNeg, eternaBleachBypass, nostalgicNeg, realaAce
}
public enum WhiteBalanceMode: String, CaseIterable, Codable, Sendable, Hashable {
  case auto, daylight, shade, fluorescent1, fluorescent2, fluorescent3, incandescent, underwater,
    temperature, autoWhitePriority, autoAmbiencePriority, custom1, custom2, custom3
}
public enum GrainStrength: String, CaseIterable, Codable, Sendable, Hashable {
  case off, weak, strong
}
public enum GrainSize: String, CaseIterable, Codable, Sendable, Hashable { case small, large }
public enum EffectStrength: String, CaseIterable, Codable, Sendable, Hashable {
  case off, weak, strong
}
public struct GrainSettings: Codable, Sendable, Hashable {
  public var strength: GrainStrength
  public var size: GrainSize?
  public init(strength: GrainStrength, size: GrainSize?) {
    self.strength = strength
    self.size = size
  }
}
public struct RecipeSettings: Codable, Sendable, Hashable {
  public var film: FilmSimulation
  public var grain: GrainSettings
  public var dynamicRange: Int
  public var whiteBalance: WhiteBalanceMode
  public var whiteBalanceRed: Int
  public var whiteBalanceBlue: Int
  public var kelvin: Int?
  public var highlightTenths: Int
  public var shadowTenths: Int
  public var colorTenths: Int
  public var sharpnessTenths: Int
  public var noiseReduction: Int
  public var colorChrome: EffectStrength?
  public var colorChromeBlue: EffectStrength?
  public var clarityTenths: Int?
  public var lensOptimizerRequested: Bool?
  public var colorSpace: String { "sRGB" }
  public init(
    film: FilmSimulation, grain: GrainSettings, dynamicRange: Int, whiteBalance: WhiteBalanceMode,
    whiteBalanceRed: Int, whiteBalanceBlue: Int, kelvin: Int? = nil, highlightTenths: Int,
    shadowTenths: Int, colorTenths: Int, sharpnessTenths: Int, noiseReduction: Int,
    colorChrome: EffectStrength? = nil, colorChromeBlue: EffectStrength? = nil,
    clarityTenths: Int? = nil, lensOptimizerRequested: Bool? = nil
  ) {
    self.film = film
    self.grain = grain
    self.dynamicRange = dynamicRange
    self.whiteBalance = whiteBalance
    self.whiteBalanceRed = whiteBalanceRed
    self.whiteBalanceBlue = whiteBalanceBlue
    self.kelvin = kelvin
    self.highlightTenths = highlightTenths
    self.shadowTenths = shadowTenths
    self.colorTenths = colorTenths
    self.sharpnessTenths = sharpnessTenths
    self.noiseReduction = noiseReduction
    self.colorChrome = colorChrome
    self.colorChromeBlue = colorChromeBlue
    self.clarityTenths = clarityTenths
    self.lensOptimizerRequested = lensOptimizerRequested
  }

}
public enum RecipeSettingID: String, CaseIterable, Codable, Sendable, Hashable {
  case film, dynamicRange, grain, colorChrome, colorChromeBlue, whiteBalance, whiteBalanceRed,
    whiteBalanceBlue, kelvin, highlight, shadow, color, sharpness, noiseReduction, clarity,
    lensOptimizer
}
public enum RecipeSettingValue: Codable, Sendable, Hashable {
  case film(FilmSimulation)
  case whiteBalance(WhiteBalanceMode)
  case grain(GrainSettings)
  case effect(EffectStrength)
  case integer(Int)
}
public enum SettingEvidence: String, Codable, Sendable, Hashable {
  case jpegObserved, profileConfirmed
}
public struct RecipeAssessment: Sendable, Equatable {
  public let settings: RecipeSettings?
  public let issues: [RecipeRenderingIssue]
  public var renderingSupport: RecipeRenderingSupport {
    if let settings, issues.isEmpty { return .supported(settings) }
    return .unsupported(issues)
  }
  public func requireSettings() throws -> RecipeSettings {
    guard let settings, issues.isEmpty else { throw RecipeImportError.unsupportedRendering(issues) }
    return settings
  }
  public init(settings: RecipeSettings? = nil, issues: [RecipeRenderingIssue]) {
    self.settings = settings
    self.issues = issues
  }

}
