import Foundation

public enum FeatureSupport: String, Codable, Sendable { case absent, unimplemented, supported }
public struct RecipeSlot: Sendable, Codable, Hashable, Identifiable {
  public let id: Int
  public let label: String
  public init(id: Int, label: String) {
    self.id = id
    self.label = label
  }

}
public struct SettingChoice: Sendable, Codable, Hashable {
  public let value: RecipeSettingValue
  public let label: String
  public init(value: RecipeSettingValue, label: String) {
    self.value = value
    self.label = label
  }

}
public struct SettingCapability: Sendable, Codable, Equatable {
  public let support: FeatureSupport
  public var editableChoices: [SettingChoice] = []
  public var renderableChoices: [SettingChoice] = []
  public var minimum: Int? = nil
  public var maximum: Int? = nil
  public var step: Int? = nil
  public func accepts(_ value: RecipeSettingValue, rendering: Bool) -> Bool {
    guard support == .supported else { return false }
    let choices = rendering ? renderableChoices : editableChoices
    if !choices.isEmpty { return choices.contains { $0.value == value } }
    if case .integer(let n) = value, let minimum, let maximum, let step, step > 0 {
      return (minimum...maximum).contains(n) && (n - minimum) % step == 0
    }
    return false
  }
  public init(
    support: FeatureSupport, editableChoices: [SettingChoice] = [],
    renderableChoices: [SettingChoice] = [], minimum: Int? = nil, maximum: Int? = nil,
    step: Int? = nil
  ) {
    self.support = support
    self.editableChoices = editableChoices
    self.renderableChoices = renderableChoices
    self.minimum = minimum
    self.maximum = maximum
    self.step = step
  }

}
public struct SourceConstraints: Sendable, Codable, Equatable {
  public let model: String
  public let recordedWidth: Int
  public let recordedHeight: Int
  public let orientations: Set<Int>
  public init(model: String, recordedWidth: Int, recordedHeight: Int, orientations: Set<Int>) {
    self.model = model
    self.recordedWidth = recordedWidth
    self.recordedHeight = recordedHeight
    self.orientations = orientations
  }

}
public struct CameraCapabilities: Sendable, Codable, Equatable {
  public let bankSlots: [RecipeSlot]
  public let settings: [RecipeSettingID: SettingCapability]
  public let recipeImport: FeatureSupport
  public let sourceConstraints: SourceConstraints
  public init(
    bankSlots: [RecipeSlot], settings: [RecipeSettingID: SettingCapability],
    recipeImport: FeatureSupport, sourceConstraints: SourceConstraints
  ) {
    self.bankSlots = bankSlots
    self.settings = settings
    self.recipeImport = recipeImport
    self.sourceConstraints = sourceConstraints
  }

}
