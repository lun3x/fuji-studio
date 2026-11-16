/// Opt-in milestones for the manual identity probe. The vocabulary deliberately excludes
/// packet contents, peer identity, endpoint strings, and arbitrary error descriptions.
public enum WirelessIdentityTrace {
  public typealias Observer = @Sendable (Event) -> Void

  public enum Stage: String, Sendable, Codable {
    case attempt, identityDeadline, identityCancellation, tcpConnect, socketRead, socketClose
    case initializationWrite, initializationHeader, initializationBody, initializationACK
    case openSessionDelay
    case openSessionWrite, openSessionHeader, openSessionData, openSessionFinalHeader, openSessionResponseBody
    case getDeviceInfoWrite, getDeviceInfoHeader, getDeviceInfoData, getDeviceInfoFinalHeader, getDeviceInfoResponseBody
    case deviceInfoValidation
    case closeSessionWrite, closeSessionHeader, closeSessionData, closeSessionFinalHeader, closeSessionResponseBody
    case sessionCleanup, otherCommand
  }

  public enum Action: String, Sendable, Codable {
    case waiting, completed, failed, readRequested, readCompleted, noData, endOfStream
  }

  public enum Failure: String, Sendable, Codable {
    case cancelled, outerDeadline, tcpSetupTimeout, transactionInactivity
    case localNetworkPermission, routeUnavailable, connectionLost, malformedData
    case authentication, peerMismatch, unsupported, rejected, other

    public init(_ error: any Error) {
      if error is CancellationError { self = .cancelled; return }
      if let error = error as? WirelessFailure {
        switch error {
        case .timeout(.tcpSetup): self = .tcpSetupTimeout
        case .timeout(.transactionInactivity): self = .transactionInactivity
        case .permissionDenied(.localNetwork): self = .localNetworkPermission
        case .routeUnavailable: self = .routeUnavailable
        case .connectionLost: self = .connectionLost
        case .malformedData: self = .malformedData
        case .authentication: self = .authentication
        case .peerMismatch: self = .peerMismatch
        case .unsupportedProtocol, .unsupportedFirmware: self = .unsupported
        default: self = .other
        }
      } else if let error = error as? PTPError {
        switch error {
        case .authorizationDenied: self = .authentication
        case .notConnected: self = .connectionLost
        case .timeout: self = .transactionInactivity
        case .responseCode: self = .rejected
        case .truncatedContainer, .oversizedContainer, .invalidContainerLength, .unexpectedContainerType,
             .invalidOpcode, .wrongTransaction, .payloadTooLarge, .sessionFailure:
          self = .malformedData
        default: self = .other
        }
      } else {
        self = .other
      }
    }
  }

  public struct Event: Sendable, Codable, Equatable {
    public let stage: Stage
    public let action: Action
    public let bytes: Int?
    public let failure: Failure?

    public init(_ stage: Stage, _ action: Action, bytes: Int? = nil, failure: Failure? = nil) {
      self.stage = stage
      self.action = action
      self.bytes = bytes.map { min(max($0, 0), 65_536) }
      self.failure = failure
    }
  }
}
