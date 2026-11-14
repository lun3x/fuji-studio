import Foundation

public enum WirelessCameraModel: String, Codable, Sendable {
  case xt5 = "X-T5"
  case xe3 = "X-E3"
}

public enum WirelessMode: String, Codable, Sendable {
  case xApp
  case phone
  case autoSave
}

public struct WirelessCameraID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: UUID

  /// Generate a new ID after an explicit pairing, then reuse the persisted ID for this camera.
  public init() {
    self.init(rawValue: UUID())
  }

  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }
}

public struct WirelessProtocolPeerKey: Equatable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  /// Use protected storage for these bytes if the protocol requires persistence.
  public let bytes: Data

  public init(bytes: Data) {
    self.bytes = bytes
  }

  public var description: String { "[redacted]" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
}

public struct WirelessIdentity: Equatable, Sendable {
  public let cameraID: WirelessCameraID
  public let model: WirelessCameraModel
  /// Keep the original firmware string available for protected evidence.
  public let firmware: String?
  public let protocolPeerKey: WirelessProtocolPeerKey?

  public init(
    cameraID: WirelessCameraID,
    model: WirelessCameraModel,
    firmware: String?,
    protocolPeerKey: WirelessProtocolPeerKey? = nil
  ) {
    self.cameraID = cameraID
    self.model = model
    self.firmware = firmware
    self.protocolPeerKey = protocolPeerKey
  }
}

public enum WirelessAdmission: Equatable, Sendable {
  case supported(WirelessCameraModel)
  case updateRequired(String)
  /// The original input is available for protected evidence.
  case unverified(String?)
  case unsupportedModel
}

public enum WirelessRAWExposure: Equatable, Sendable {
  case available
  case unavailable
  case unknown
}

/// Observations from the negotiated transfer session. Firmware admission must be checked separately.
public struct WirelessCapabilities: Equatable, Sendable {
  public let mode: WirelessMode
  public let rawExposure: WirelessRAWExposure
  public let storageIDs: [UInt32]
  public let originalSizeVerified: Bool
  public let evidenceID: String

  public init(
    mode: WirelessMode,
    rawExposure: WirelessRAWExposure,
    storageIDs: [UInt32],
    originalSizeVerified: Bool,
    evidenceID: String
  ) {
    self.mode = mode
    self.rawExposure = rawExposure
    self.storageIDs = storageIDs
    self.originalSizeVerified = originalSizeVerified
    self.evidenceID = evidenceID
  }
}

public enum WirelessPermissionKind: Equatable, Sendable {
  case bluetooth
  case localNetwork
  case wifiJoin
  case photos
}

public enum WirelessTimeoutStage: Equatable, Sendable {
  case savedReconnect
  case firstPairing
  case wifiReadiness
  case joinResult
  case tcpSetup
  case transactionInactivity
  case autoSaveRegistration
}

public enum WirelessFailure: Error, Equatable, Sendable {
  case permissionDenied(WirelessPermissionKind)
  case authentication
  case unsupportedFirmware
  case unsupportedProtocol
  case timeout(WirelessTimeoutStage)
  case peerMismatch
  case malformedData
  case unavailableStorage
  case connectionLost
}
