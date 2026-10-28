import Foundation

public struct CameraAdapterID: Sendable, Codable, Hashable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

}
public enum RecipeImportSessionPolicy: Sendable { case currentVerifiedSession, freshBeforeAndAfter }
public enum CapabilityOrigin: String, Sendable, Codable { case cameraReported, applicationDefined }
public struct VerifiedCameraSupport: Sendable, Equatable {
  public let adapterID: CameraAdapterID
  public let model: String
  public let firmware: String
  public let capability: String
  public let capabilityOrigin: CapabilityOrigin
  public let supportVersion: String
  public let capabilities: CameraCapabilities
  public init(
    adapterID: CameraAdapterID, model: String, firmware: String, capability: String,
    capabilityOrigin: CapabilityOrigin, supportVersion: String, capabilities: CameraCapabilities
  ) {
    self.adapterID = adapterID
    self.model = model
    self.firmware = firmware
    self.capability = capability
    self.capabilityOrigin = capabilityOrigin
    self.supportVersion = supportVersion
    self.capabilities = capabilities
  }

}
public struct DecodedRecipeCollection: Sendable {
  public let recipes: [RecipeSnapshot]
  public let declaredSlots: [RecipeSlot]
  public init(recipes: [RecipeSnapshot], declaredSlots: [RecipeSlot]) {
    self.recipes = recipes
    self.declaredSlots = declaredSlots
  }

}
public struct ImportedRecipeCollection: Sendable {
  public let recipes: [RecipeSnapshot]
  public let declaredSlots: [RecipeSlot]
  public let context: CameraExecutionContext
  public let support: VerifiedCameraSupport
  public init(
    recipes: [RecipeSnapshot], declaredSlots: [RecipeSlot], context: CameraExecutionContext,
    support: VerifiedCameraSupport
  ) {
    self.recipes = recipes
    self.declaredSlots = declaredSlots
    self.context = context
    self.support = support
  }

}
public struct FujiRAWConversionDialect: Sendable {
  public let uploadInfoOpcode: UInt16
  public let uploadOpcode: UInt16
  public let profileProperty: UInt32
  public let triggerProperty: UInt32
  public let triggerValue: Data
  public let outputAssociationTypes: Set<UInt16>
  public static let xt5 = FujiRAWConversionDialect(
    uploadInfoOpcode: 0x900C, uploadOpcode: 0x900D, profileProperty: 0xD185,
    triggerProperty: 0xD183, triggerValue: Data([1, 0]), outputAssociationTypes: [0, 2055])
  public func uploadInfo(byteCount: Int) throws -> Data {
    try FujiConversionCodec.uploadInfo(byteCount: byteCount)
  }
  public init(
    uploadInfoOpcode: UInt16, uploadOpcode: UInt16, profileProperty: UInt32,
    triggerProperty: UInt32, triggerValue: Data, outputAssociationTypes: Set<UInt16>
  ) {
    self.uploadInfoOpcode = uploadInfoOpcode
    self.uploadOpcode = uploadOpcode
    self.profileProperty = profileProperty
    self.triggerProperty = triggerProperty
    self.triggerValue = triggerValue
    self.outputAssociationTypes = outputAssociationTypes
  }

}
public struct PreparedConversion: Sendable {
  public let bytes: Data
  public let requested: RecipeSettings
  public let source: RAWMetadata
  public let supportVersion: String
  public let expectedLensOptimizer: Bool
  public let baselineSHA256: String
  public let candidateSHA256: String
  public init(
    bytes: Data, requested: RecipeSettings, source: RAWMetadata, supportVersion: String,
    expectedLensOptimizer: Bool, baselineSHA256: String, candidateSHA256: String
  ) {
    self.bytes = bytes
    self.requested = requested
    self.source = source
    self.supportVersion = supportVersion
    self.expectedLensOptimizer = expectedLensOptimizer
    self.baselineSHA256 = baselineSHA256
    self.candidateSHA256 = candidateSHA256
  }

}
public struct TemporaryBankSelector: Sendable {
  public let property: UInt16
  public let slots: Set<UInt16>
  public init(property: UInt16, slots: Set<UInt16>) {
    self.property = property
    self.slots = slots
  }
}
public protocol FujiCameraAdapter: Sendable {
  var id: CameraAdapterID { get }
  var model: String { get }
  var conversionDialect: FujiRAWConversionDialect { get }
  var temporaryBankSelector: TemporaryBankSelector? { get }
  var recipeImportSessionPolicy: RecipeImportSessionPolicy { get }
  func verifyDevice(_ device: FujiDeviceInfo, io: CameraOperationIO) async throws
    -> VerifiedCameraSupport
  func importRecipes(
    io: CameraOperationIO, support: VerifiedCameraSupport, context: RecipeCameraContext
  ) async throws -> DecodedRecipeCollection
  func decodeRecipe(_ snapshot: RecipeSnapshot) throws -> RecipeAssessment
  func encodeEditedRecipe(_ settings: RecipeSettings, preserving snapshot: RecipeSnapshot) throws
    -> RecipeSnapshot
  func validateSource(_ source: RAWMetadata) throws
  func prepareConversion(
    baseline: Data, source: RAWMetadata, recipe: RecipeSnapshot, support: VerifiedCameraSupport,
    policy: OutputPolicy
  ) throws -> PreparedConversion
  func validateOutput(_ jpeg: Data, conversion: PreparedConversion) throws -> CameraOutputAssessment
}
