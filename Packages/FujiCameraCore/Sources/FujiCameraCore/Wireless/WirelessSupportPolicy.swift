import Foundation

/// Bundled firmware admission for wireless import.
public struct WirelessSupportPolicy: Sendable {
  public struct Record: Sendable {
    public enum FirmwareRule: Sendable {
      case minimum
      case exact
    }

    public let firmware: String
    public let firmwareRule: FirmwareRule
    public let instructionsURL: URL

    public var firmwareRequirement: String {
      switch firmwareRule {
      case .minimum: "\(firmware) or later"
      case .exact: firmware
      }
    }
  }

  public init() {}

  public func record(for model: WirelessCameraModel) -> Record {
    switch model {
    case .xt5:
      Record(
        firmware: "4.30",
        firmwareRule: .minimum,
        instructionsURL: URL(
          string: "https://www.fujifilm-x.com/en-us/support/download/firmware/cameras/x-t5/")!
      )
    case .xe3:
      Record(
        firmware: "1.32",
        firmwareRule: .exact,
        instructionsURL: URL(
          string: "https://www.fujifilm-x.com/en-us/support/download/firmware/cameras/x-e3/")!
      )
    }
  }

  public func assess(model: String, firmware: String?) -> WirelessAdmission {
    guard let model = WirelessCameraModel(rawValue: model) else { return .unsupportedModel }
    guard let firmware else { return .unverified(.unreadable) }

    var normalized = firmware.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.hasPrefix("Ver.") {
      normalized = normalized.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let record = record(for: model)
    guard let observed = versionComponents(normalized),
      let required = versionComponents(record.firmware)
    else { return .unverified(.unreadable) }

    if observed < required { return .updateRequired(record.firmware) }
    switch record.firmwareRule {
    case .minimum:
      return .supported(model)
    case .exact:
      if normalized == record.firmware { return .supported(model) }
      if observed > required { return .unverified(.newer) }
      return .unverified(.unreadable)
    }
  }

  private func versionComponents(_ firmware: String) -> (major: UInt, minor: UInt)? {
    let components = firmware.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 2,
      components.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
      let major = UInt(components[0]), let minor = UInt(components[1])
    else { return nil }
    return (major, minor)
  }
}
