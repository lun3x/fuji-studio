import Foundation

/// Bundled firmware admission for wireless import.
public struct WirelessSupportPolicy: Sendable {
  public struct Record: Sendable {
    public let firmware: String
    public let instructionsURL: URL
  }

  public init() {}

  public func record(for model: WirelessCameraModel) -> Record {
    switch model {
    case .xt5:
      Record(
        firmware: "4.32",
        instructionsURL: URL(
          string: "https://www.fujifilm-x.com/en-us/support/download/firmware/cameras/x-t5/")!
      )
    case .xe3:
      Record(
        firmware: "1.32",
        instructionsURL: URL(
          string: "https://www.fujifilm-x.com/en-us/support/download/firmware/cameras/x-e3/")!
      )
    }
  }

  public func assess(model: String, firmware: String?) -> WirelessAdmission {
    guard let model = WirelessCameraModel(rawValue: model) else { return .unsupportedModel }
    guard let firmware else { return .unverified(nil) }

    var normalized = firmware.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.hasPrefix("Ver.") {
      normalized = normalized.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let target = record(for: model).firmware
    if normalized == target { return .supported(model) }

    if let observed = versionComponents(normalized), let required = versionComponents(target),
      observed < required
    {
      return .updateRequired(target)
    }
    return .unverified(firmware)
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
