import Foundation

public enum XE3Support {
  public static let identifier = "xe3-1.30-FF129505-v1"
  public static let conversionVersion = "xe3-1.30-FF129505-v3-standard-recipes"
}
public enum XE3Capabilities {
  // Every native preset was checked against the camera JPEG's Fuji ColorTemperature.
  // Arbitrary values (for example 5310) read back unchanged but render as 2500 K.
  public static let verifiedKelvin: Set<Int> = Set(XE3NativeRecipeFields.kelvin)
  public static let measured: CameraCapabilities = {
    func choices(_ values: [RecipeSettingValue]) -> SettingCapability {
      let list = values.map { SettingChoice(value: $0, label: $0.label) }
      return .init(support: .supported, editableChoices: list, renderableChoices: list)
    }
    func range(_ min: Int, _ max: Int, _ step: Int = 1) -> SettingCapability {
      .init(support: .supported, minimum: min, maximum: max, step: step)
    }
    let settings: [RecipeSettingID: SettingCapability] = [
      .film: choices(
        FilmSimulation.allCases.filter {
          XE3NativeRecipeFields.films.values.contains($0)
        }.map(RecipeSettingValue.film)),
      .grain: choices(GrainStrength.allCases.map { .grain(.init(strength: $0, size: nil)) }),
      .dynamicRange: .init(
        support: .supported,
        editableChoices: [0, 100, 200, 400].map {
          .init(value: .integer($0), label: $0 == 0 ? "Auto" : "\($0)%")
        },
        renderableChoices: [100, 200, 400].map { .init(value: .integer($0), label: "\($0)%") }),
      .whiteBalance: choices(
        WhiteBalanceMode.allCases.filter {
          XE3NativeRecipeFields.whiteBalances.values.contains($0)
        }.map(RecipeSettingValue.whiteBalance)),
      .whiteBalanceRed: range(-9, 9), .whiteBalanceBlue: range(-9, 9),
      .kelvin: choices(verifiedKelvin.sorted().map(RecipeSettingValue.integer)),
      .highlight: range(-20, 40, 10), .shadow: range(-20, 40, 10), .color: range(-40, 40, 10),
      .sharpness: range(-40, 40, 10), .noiseReduction: range(-4, 4),
      .colorChrome: .init(support: .absent), .colorChromeBlue: .init(support: .absent),
      .clarity: .init(support: .absent), .lensOptimizer: .init(support: .absent),
    ]
    return .init(
      bankSlots: (1...7).map { .init(id: $0, label: "C\($0)") }, settings: settings,
      recipeImport: .supported,
      sourceConstraints: .init(
        model: "X-E3", recordedWidth: 6000, recordedHeight: 4000, orientations: [1, 8]))
  }()
  public static func validate(_ settings: RecipeSettings) throws {
    guard settings.colorChrome == nil, settings.colorChromeBlue == nil,
      settings.clarityTenths == nil,
      settings.grain.size == nil
    else { throw CameraServiceError.unsupportedSettings }
    for (id, value) in settings.values {
      if id == .kelvin && settings.whiteBalance != .temperature { continue }
      guard measured.settings[id]?.accepts(value, rendering: true) == true else {
        throw CameraServiceError.unsupportedSettings
      }
    }
    if settings.whiteBalance == .temperature {
      guard let kelvin = settings.kelvin, verifiedKelvin.contains(kelvin) else {
        throw CameraServiceError.unsupportedSettings
      }
    }
  }
}
