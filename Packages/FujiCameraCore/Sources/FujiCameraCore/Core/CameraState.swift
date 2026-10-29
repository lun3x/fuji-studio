import Foundation

public struct CameraConnection: Sendable, Equatable {
  public let name: String
  public let usbVendorID: Int
  public let usbProductID: Int
  /// Process-local physical attachment continuity; never a persistent camera identity.
  public let attachmentIdentity: UUID?
  public init(name: String, usbVendorID: Int, usbProductID: Int, attachmentIdentity: UUID? = nil) {
    self.name = name
    self.usbVendorID = usbVendorID
    self.usbProductID = usbProductID
    self.attachmentIdentity = attachmentIdentity
  }

}

public struct CameraSession: Sendable, Equatable {
  public let generation: UInt64
  public let connection: CameraConnection
  public init(generation: UInt64, connection: CameraConnection) {
    self.generation = generation
    self.connection = connection
  }

}

public enum CameraState: Sendable, Equatable {
  case disconnected
  case discovering
  case authorizationRequired
  case authorizationDenied
  case opening
  /// Public USB PTP session only. RAW conversion mode, firmware and model remain unverified.
  case sessionOpen(CameraSession)
  /// Reserved for the higher camera service after it verifies conversion capability.
  case ready(CameraSession)
  case busy(CameraSession)
  /// The USB session is retained, but further work needs an explicit reset.
  case attentionRequired(CameraSession, message: String)
  case wrongMode(String)
  case recoverableError(PTPError)
}
