import Foundation

public struct XT5Adapter: FujiCameraAdapter {
  public typealias JPEGValidator = @Sendable (Data, RAWMetadata) throws -> ValidatedJPEGMetadata
  private let validateJPEG: JPEGValidator
  public init(
    validateJPEG: @escaping JPEGValidator = {
      try FujiConversionCodec.validateFullSizeFineJPEG($0, expected: $1)
    }
  ) { self.validateJPEG = validateJPEG }
  public let id = CameraAdapterID(rawValue: "fujifilm.xt5")
  public let model = "X-T5"
  public let temporaryBankSelector: TemporaryBankSelector? = .init(
    property: 0xD18C, slots: Set(1...7))
  public let conversionDialect = FujiRAWConversionDialect.xt5
  public let recipeImportSessionPolicy = RecipeImportSessionPolicy.currentVerifiedSession
  public func verifyDevice(_ device: FujiDeviceInfo, io: CameraOperationIO) async throws
    -> VerifiedCameraSupport
  {
    guard device.manufacturer == "FUJIFILM", device.model == model, device.firmware == "4.31",
      [UInt16(0x1005), 0x1007, 0x1008, 0x1009, 0x100B, 0x1015, 0x1016, 0x900C, 0x900D].allSatisfy(
        device.operations.contains),
      ([UInt16(0xD16E), 0xD183, 0xD185, 0xD186, 0xD187, 0xD18C, 0xD18D] + Array(0xD18E...0xD1A4))
        .allSatisfy(device.properties.contains),
      try await io.readProperty(0xD16E) == Data([6, 0])
    else { throw CameraServiceError.unsupportedContext }
    for property: UInt16 in [0xD186, 0xD187] {
      guard
        try PTPDatasets.value(await io.readProperty(property), type: 0xffff).string == "X-T5_0200"
      else { throw CameraServiceError.unsupportedContext }
    }
    return VerifiedCameraSupport(
      adapterID: id, model: model, firmware: device.firmware, capability: "X-T5_0200",
      capabilityOrigin: .cameraReported, supportVersion: XT5WorkingProfile.supportVersion,
      capabilities: RecipeCodecRegistry.xt5Capabilities)
  }
  public func importRecipes(
    io: CameraOperationIO, support: VerifiedCameraSupport, context: RecipeCameraContext
  ) async throws -> DecodedRecipeCollection {
    let importer = XT5BankImporter(
      transport: try await io.temporarySelectorTransport(),
      sessionGeneration: context.sessionGeneration,
      validateSession: { try await io.validateActive() }, settle: { try await io.settle($0) })
    do {
      let result = try await importer.importRecipesVerified()
      guard result.evidence.complete else { throw CameraServiceError.unsupportedContext }
      return DecodedRecipeCollection(
        recipes: result.recipes, declaredSlots: support.capabilities.bankSlots)
    } catch let failure as XT5BankImportFailure { throw Self.importFailure(failure) }
  }
  public static func importFailure(_ error: XT5BankImportFailure) -> CameraServiceError {
    .recipeImportFailed(
      restorationConfirmed: error.evidence.restoration == .verified
        || error.evidence.restoration == .notNeeded)
  }

  public func decodeRecipe(_ snapshot: RecipeSnapshot) throws -> RecipeAssessment {
    RecipeCodecRegistry().assess(snapshot)
  }
  public func encodeEditedRecipe(_ settings: RecipeSettings, preserving snapshot: RecipeSnapshot)
    throws -> RecipeSnapshot
  { try XT5RecipeSettingsCodec.encode(settings, preserving: snapshot) }
  public func validateSource(_ source: RAWMetadata) throws {
    try XT5WorkingProfile.validateSource(source)
  }
  public func prepareConversion(
    baseline: Data, source: RAWMetadata, recipe: RecipeSnapshot, support: VerifiedCameraSupport,
    policy: OutputPolicy
  ) throws -> PreparedConversion {
    let patch = try XT5WorkingProfile.make(baseline: baseline, recipe: recipe, metadata: source)
    return PreparedConversion(
      bytes: patch.bytes, requested: patch.settings, source: source,
      supportVersion: support.supportVersion, expectedLensOptimizer: true,
      baselineSHA256: patch.baselineSHA256, candidateSHA256: patch.candidateSHA256)
  }
  public func validateOutput(_ jpeg: Data, conversion: PreparedConversion) throws
    -> CameraOutputAssessment
  {
    let metadata = try validateJPEG(jpeg, conversion.source)
    guard let lmo = metadata.lensOptimizer else { throw CameraServiceError.invalidOutput }
    guard lmo == conversion.expectedLensOptimizer else {
      return CameraOutputAssessment(
        metadata: metadata,
        admission: .rejected(
          .init(
            field: "lensOptimizer", requested: String(conversion.expectedLensOptimizer),
            observed: String(lmo))))
    }
    var evidence = Dictionary(
      uniqueKeysWithValues: conversion.requested.values.keys.map {
        ($0, SettingEvidence.profileConfirmed)
      })
    evidence[.lensOptimizer] = .jpegObserved
    let report = EffectiveRecipeReport(
      supportVersion: conversion.supportVersion, requested: conversion.requested,
      dormantGrainSizeNotSerialized: conversion.requested.grain.strength == .off,
      inactiveKelvinPreserved: conversion.requested.whiteBalance != .temperature,
      lensOptimizerRequested: conversion.expectedLensOptimizer, lensOptimizerEffective: lmo,
      lensOptimizerAdjusted: false,
      evidence:
        "Exact profile readback within measured X-T5 domain; JPEG identity, FINE, geometry and LMO observed.",
      evidenceBySetting: evidence)
    return CameraOutputAssessment(metadata: metadata, admission: .accepted(report))
  }
}
