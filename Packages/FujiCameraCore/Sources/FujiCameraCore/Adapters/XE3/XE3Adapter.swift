import Foundation

public struct XE3Adapter: FujiCameraAdapter {
  public let id = CameraAdapterID(rawValue: "fujifilm.xe3")
  public let model = "X-E3"
  public let temporaryBankSelector: TemporaryBankSelector? = nil
  public let recipeImportSessionPolicy = RecipeImportSessionPolicy.freshBeforeAndAfter
  public let conversionDialect = FujiRAWConversionDialect(
    uploadInfoOpcode: 0x900C, uploadOpcode: 0x900D, profileProperty: 0xD185,
    triggerProperty: 0xD183, triggerValue: Data([1, 0]), outputAssociationTypes: [7, 2055])
  public init() {}
  public func verifyDevice(_ device: FujiDeviceInfo, io: CameraOperationIO) async throws
    -> VerifiedCameraSupport
  {
    guard device.manufacturer == "FUJIFILM", device.model == model, device.firmware == "1.30",
      [UInt16(0x1001), 0x1005, 0x1007, 0x1008, 0x1009, 0x100B, 0x1015, 0x1016, 0x900C, 0x900D]
        .allSatisfy(device.operations.contains), try await io.readProperty(0xD16E) == Data([6, 0])
    else { throw CameraServiceError.unsupportedContext }
    return .init(
      adapterID: id, model: model, firmware: device.firmware, capability: XE3Support.identifier,
      capabilityOrigin: .applicationDefined, supportVersion: XE3Support.conversionVersion,
      capabilities: XE3Capabilities.measured)
  }
  public func importRecipes(
    io: CameraOperationIO, support: VerifiedCameraSupport, context: RecipeCameraContext
  ) async throws -> DecodedRecipeCollection {
    try XE3BackupRecipeCodec.decode(
      await io.readSettingsBackup(), context: context, importedAt: Date())
  }
  public func decodeRecipe(_ snapshot: RecipeSnapshot) throws -> RecipeAssessment {
    XE3RecipeCodec.assess(snapshot)
  }
  public func encodeEditedRecipe(_ settings: RecipeSettings, preserving snapshot: RecipeSnapshot)
    throws -> RecipeSnapshot
  { try XE3RecipeCodec.encodeEditedRecipe(settings, preserving: snapshot) }
  public func validateSource(_ source: RAWMetadata) throws { try XE3SourceRules.validate(source) }
  public func prepareConversion(
    baseline: Data, source: RAWMetadata, recipe: RecipeSnapshot, support: VerifiedCameraSupport,
    policy: OutputPolicy
  ) throws -> PreparedConversion {
    try XE3WorkingProfile.make(
      baseline: baseline, settings: XE3RecipeCodec.assess(recipe).requireSettings(), source: source)
  }
  public func validateOutput(_ jpeg: Data, conversion: PreparedConversion) throws
    -> CameraOutputAssessment
  {
    let metadata = try FujiConversionCodec.validateFullSizeFineJPEG(
      jpeg, expected: conversion.source)
    var required: Set<RecipeSettingID> = [
      .film, .grain, .dynamicRange, .whiteBalance, .whiteBalanceRed, .whiteBalanceBlue, .highlight,
      .shadow, .sharpness, .noiseReduction,
    ]
    if conversion.requested.whiteBalance == .temperature { required.insert(.kelvin) }
    let monochrome: Set<FilmSimulation> = [
      .monochrome, .monochromeYellow, .monochromeRed, .monochromeGreen, .sepia, .acros,
      .acrosYellow, .acrosRed, .acrosGreen,
    ]
    if !monochrome.contains(conversion.requested.film) { required.insert(.color) }
    return try CameraOutputAssessment.assess(
      metadata: metadata, conversion: conversion, required: required)
  }
}
