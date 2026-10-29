import Foundation

public struct RecipeCodecRegistry: Sendable {
  public init() {}
  public func assess(_ snapshot: RecipeSnapshot) -> RecipeAssessment {
    if snapshot.cameraContext.model == "X-E3" { return XE3RecipeCodec.assess(snapshot) }
    do {
      return RecipeAssessment(settings: try requireModelSettings(snapshot), issues: [])
    } catch CameraServiceError.unsupportedContext {
      return .init(settings: nil, issues: [.unsupportedCameraContext])
    } catch {
      return .init(settings: try? editableSettings(snapshot), issues: [.unsupportedMeasuredDomain])
    }
  }
  public func requireSettings(_ snapshot: RecipeSnapshot) throws -> RecipeSettings {
    try assess(snapshot).requireSettings()
  }
  public func editableSettings(_ snapshot: RecipeSnapshot) throws -> RecipeSettings {
    try verify(snapshot.cameraContext)
    if snapshot.cameraContext.model == "X-E3" { return try XE3RecipeCodec.decode(snapshot) }
    return try XT5RecipeSettingsCodec.decode(snapshot)
  }
  public func encodeEditedRecipe(_ settings: RecipeSettings, preserving snapshot: RecipeSnapshot)
    throws -> RecipeSnapshot
  {
    try verify(snapshot.cameraContext)
    if snapshot.cameraContext.model == "X-E3" {
      return try XE3RecipeCodec.encodeEditedRecipe(settings, preserving: snapshot)
    }
    return try XT5RecipeSettingsCodec.encode(settings, preserving: snapshot)
  }
  public func capabilities(for context: RecipeCameraContext) throws -> CameraCapabilities {
    try verify(context)
    return context.model == "X-E3" ? XE3Capabilities.measured : Self.xt5Capabilities
  }
  public func supportVersion(for context: RecipeCameraContext) throws -> String {
    try verify(context)
    return context.model == "X-E3" ? XE3Support.identifier : XT5WorkingProfile.supportVersion
  }
  private func verify(_ context: RecipeCameraContext) throws {
    if context.model == "X-E3", context.firmware == "1.30",
      context.capability == XE3Support.identifier
    {
      return
    }
    guard context.model == "X-T5", context.firmware == "4.31", context.capability == "X-T5_0200"
    else { throw CameraServiceError.unsupportedContext }
  }
  private func requireModelSettings(_ snapshot: RecipeSnapshot) throws -> RecipeSettings {
    try verify(snapshot.cameraContext)
    return try XT5WorkingProfile.normalize(snapshot)
  }
  public static let xt5Capabilities: CameraCapabilities = {
    func choices(_ values: [RecipeSettingValue]) -> [SettingChoice] {
      values.map { .init(value: $0, label: $0.label) }
    }
    func choice(_ values: [RecipeSettingValue], rendering: [RecipeSettingValue]? = nil)
      -> SettingCapability
    {
      .init(
        support: .supported, editableChoices: choices(values),
        renderableChoices: choices(rendering ?? values))
    }
    func range(_ min: Int, _ max: Int, _ step: Int = 1) -> SettingCapability {
      .init(support: .supported, minimum: min, maximum: max, step: step)
    }
    let grains = XT5GrainValues.writable.keys.sorted().compactMap {
      XT5GrainValues.writable[$0].map(RecipeSettingValue.grain)
    }
    let renderGrains: [RecipeSettingValue] = [
      .grain(.init(strength: .off, size: .small)), .grain(.init(strength: .off, size: .large)),
      .grain(.init(strength: .strong, size: .small)),
    ]
    let effects = EffectStrength.allCases.map(RecipeSettingValue.effect)
    let settings: [RecipeSettingID: SettingCapability] = [
      .film: choice(
        FilmSimulation.allCases.map(RecipeSettingValue.film),
        rendering: [
          .film(.provia), .film(.classicChrome), .film(.acros), .film(.acrosRed),
          .film(.acrosGreen),
        ]),
      .dynamicRange: choice(
        [0, 100, 200, 400].map(RecipeSettingValue.integer),
        rendering: [.integer(100), .integer(400)]),
      .grain: choice(grains, rendering: renderGrains), .colorChrome: choice(effects),
      .colorChromeBlue: choice(effects),
      .whiteBalance: choice(
        [
          .autoWhitePriority, .auto, .autoAmbiencePriority, .custom1, .custom2, .custom3,
          .temperature, .daylight, .shade, .fluorescent1, .fluorescent2, .fluorescent3,
          .incandescent, .underwater,
        ].map(RecipeSettingValue.whiteBalance),
        rendering: [.whiteBalance(.auto), .whiteBalance(.temperature)]),
      .whiteBalanceRed: range(-9, 9), .whiteBalanceBlue: range(-9, 9),
      .kelvin: range(2500, 10000, 10),
      .highlight: range(-20, 40, 5), .shadow: range(-20, 40, 5), .color: range(-40, 40, 10),
      .sharpness: range(-40, 40, 10), .noiseReduction: range(-4, 4), .clarity: range(-50, 50, 10),
    ]
    return .init(
      bankSlots: (1...7).map { .init(id: $0, label: "C\($0)") }, settings: settings,
      recipeImport: .supported,
      sourceConstraints: .init(
        model: "X-T5", recordedWidth: 7728, recordedHeight: 5152, orientations: Set(1...8)))
  }()
}
extension RecipeSettings {
  public var values: [RecipeSettingID: RecipeSettingValue] {
    var result: [RecipeSettingID: RecipeSettingValue] = [
      .film: .film(film), .grain: .grain(grain), .dynamicRange: .integer(dynamicRange),
      .whiteBalance: .whiteBalance(whiteBalance), .whiteBalanceRed: .integer(whiteBalanceRed),
      .whiteBalanceBlue: .integer(whiteBalanceBlue), .highlight: .integer(highlightTenths),
      .shadow: .integer(shadowTenths), .color: .integer(colorTenths),
      .sharpness: .integer(sharpnessTenths), .noiseReduction: .integer(noiseReduction),
    ]
    if let kelvin { result[.kelvin] = .integer(kelvin) }
    if let colorChrome { result[.colorChrome] = .effect(colorChrome) }
    if let colorChromeBlue { result[.colorChromeBlue] = .effect(colorChromeBlue) }
    if let clarityTenths { result[.clarity] = .integer(clarityTenths) }
    return result
  }
}
extension RecipeSettingValue {
  public var label: String {
    switch self {
    case .film(let film): film.displayName
    case .whiteBalance(let mode): mode.displayName
    case .grain(let grain):
      "\(grain.strength.rawValue.capitalized)"
        + (grain.size.map { " · \($0.rawValue.capitalized)" } ?? "")
    case .effect(let strength): strength.rawValue.capitalized
    case .integer(let value): String(value)
    }
  }
}
extension FilmSimulation {
  public var displayName: String {
    switch self {
    case .provia: "PROVIA / Standard"
    case .velvia: "Velvia / Vivid"
    case .astia: "ASTIA / Soft"
    case .proNegHi: "PRO Neg. Hi"
    case .proNegStd: "PRO Neg. Std"
    case .monochrome: "Monochrome"
    case .monochromeYellow: "Monochrome + Y"
    case .monochromeRed: "Monochrome + R"
    case .monochromeGreen: "Monochrome + G"
    case .sepia: "Sepia"
    case .classicChrome: "Classic Chrome"
    case .acros: "ACROS"
    case .acrosYellow: "ACROS + Y"
    case .acrosRed: "ACROS + R"
    case .acrosGreen: "ACROS + G"
    case .eterna: "ETERNA / Cinema"
    case .classicNeg: "Classic Neg."
    case .eternaBleachBypass: "ETERNA Bleach Bypass"
    case .nostalgicNeg: "Nostalgic Neg."
    case .realaAce: "REALA ACE"
    }
  }
}
extension WhiteBalanceMode {
  public var displayName: String {
    switch self {
    case .auto: "Auto"
    case .temperature: "Colour temperature"
    case .daylight: "Daylight"
    case .shade: "Shade"
    case .fluorescent1: "Fluorescent 1"
    case .fluorescent2: "Fluorescent 2"
    case .fluorescent3: "Fluorescent 3"
    case .incandescent: "Incandescent"
    case .underwater: "Underwater"
    case .autoWhitePriority: "Auto · White priority"
    case .autoAmbiencePriority: "Auto · Ambience priority"
    case .custom1: "Custom 1"
    case .custom2: "Custom 2"
    case .custom3: "Custom 3"
    }
  }
}
