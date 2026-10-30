import Foundation

/// The full storage/editor domain. Model profiles only narrow availability.
public enum StandardRecipeCatalog {
  public static let defaults: [RecipeSettingID: RecipeSettingValue] = [
    .film: .film(.provia), .dynamicRange: .integer(100),
    .grain: .grain(.init(strength: .off, size: nil)), .grainSize: .option(.small),
    .colorChrome: .effect(.off), .colorChromeBlue: .effect(.off),
    .whiteBalance: .whiteBalance(.auto), .whiteBalanceRed: .integer(0),
    .whiteBalanceBlue: .integer(0), .kelvin: .integer(5000),
    .highlight: .integer(0), .shadow: .integer(0), .color: .integer(0),
    .sharpness: .integer(0), .noiseReduction: .integer(0), .clarity: .integer(0),
    .lensOptimizer: .integer(1), .dynamicRangePriority: .option(.off),
    .monochromeWarmCool: .integer(0), .monochromeMagentaGreen: .integer(0),
    .smoothSkin: .effect(.off), .longExposureNoiseReduction: .integer(0),
    .colorSpace: .option(.sRGB), .imageSize: .option(.large), .aspectRatio: .option(.ratio3x2),
    .imageQuality: .option(.fineRAW), .rawRecording: .option(.losslessCompressed),
    .outputFormat: .option(.jpeg), .iso: .option(.auto1),
  ]

  public static func choices(for id: RecipeSettingID) -> [SettingChoice] {
    let c = global[id]!
    if !c.editableChoices.isEmpty { return c.editableChoices }
    guard let low = c.minimum, let high = c.maximum, let step = c.step else { return [] }
    return stride(from: high, through: low, by: -step).map {
      SettingChoice(value: .integer($0), label: String($0))
    }
  }

  public static func capability(for id: RecipeSettingID, camera: RecipeCameraModel)
    -> SettingCapability
  {
    if camera == .xe3 {
      if [
        .grainSize, .colorChrome, .colorChromeBlue, .clarity, .dynamicRangePriority,
        .monochromeWarmCool, .monochromeMagentaGreen, .smoothSkin, .outputFormat,
      ].contains(id) {
        return .init(support: .absent)
      }
      switch id {
      case .film, .highlight, .shadow, .kelvin:
        return XE3Capabilities.measured.settings[id]!
      case .whiteBalance:
        return options(
          WhiteBalanceMode.allCases.filter {
            ![.autoWhitePriority, .autoAmbiencePriority].contains($0)
          }.map(RecipeSettingValue.whiteBalance))
      case .aspectRatio: return options([.ratio3x2, .ratio16x9, .ratio1x1])
      case .rawRecording: return options([.uncompressed, .losslessCompressed])
      case .iso:
        return options(
          isoChoices.filter {
            guard case .integer(let n) = $0 else { return true }
            return n >= 100
          })
      default: break
      }
    }
    return global[id]!
  }

  private static func options(_ values: [RecipeSettingValue]) -> SettingCapability {
    let choices = values.map { SettingChoice(value: $0, label: $0.label) }
    return .init(support: .supported, editableChoices: choices, renderableChoices: choices)
  }
  private static func options(_ values: [RecipeOption]) -> SettingCapability {
    options(values.map(RecipeSettingValue.option))
  }
  private static func range(_ low: Int, _ high: Int, _ step: Int = 1) -> SettingCapability {
    .init(support: .supported, minimum: low, maximum: high, step: step)
  }
  private static let isoChoices: [RecipeSettingValue] =
    [RecipeOption.auto1, .auto2, .auto3].map(RecipeSettingValue.option)
    + [
      64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600,
      2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800, 25600, 51200,
    ]
    .map(RecipeSettingValue.integer)
  private static let global: [RecipeSettingID: SettingCapability] = [
    .film: options(FilmSimulation.allCases.map(RecipeSettingValue.film)),
    .grain: options(GrainStrength.allCases.map { .grain(.init(strength: $0, size: nil)) }),
    .grainSize: options([.small, .large]),
    .dynamicRange: options([400, 200, 100, 0].map(RecipeSettingValue.integer)),
    .colorChrome: options(EffectStrength.allCases.map(RecipeSettingValue.effect)),
    .colorChromeBlue: options(EffectStrength.allCases.map(RecipeSettingValue.effect)),
    .whiteBalance: options(WhiteBalanceMode.allCases.map(RecipeSettingValue.whiteBalance)),
    .whiteBalanceRed: range(-9, 9), .whiteBalanceBlue: range(-9, 9),
    .kelvin: range(2500, 10000, 10), .highlight: range(-20, 40, 5), .shadow: range(-20, 40, 5),
    .color: range(-40, 40, 10), .sharpness: range(-40, 40, 10), .noiseReduction: range(-4, 4),
    .clarity: range(-50, 50, 10), .lensOptimizer: range(0, 1),
    .dynamicRangePriority: options([.off, .weak, .strong, .auto]),
    .monochromeWarmCool: range(-180, 180, 10), .monochromeMagentaGreen: range(-180, 180, 10),
    .smoothSkin: options(EffectStrength.allCases.map(RecipeSettingValue.effect)),
    .longExposureNoiseReduction: range(0, 1), .colorSpace: options([.sRGB, .adobeRGB]),
    .imageSize: options([.large, .medium, .small]),
    .aspectRatio: options([.ratio3x2, .ratio4x3, .ratio16x9, .ratio5x4, .ratio1x1]),
    .imageQuality: options([.fine, .normal, .fineRAW, .normalRAW, .raw]),
    .rawRecording: options([.uncompressed, .losslessCompressed, .compressed]),
    .outputFormat: options([.jpeg, .heif]), .iso: options(isoChoices),
  ]
}
