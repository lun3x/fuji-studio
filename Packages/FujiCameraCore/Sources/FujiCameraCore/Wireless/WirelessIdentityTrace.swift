/// Opt-in milestones for the manual identity probe. The vocabulary deliberately excludes
/// packet contents, peer identity, endpoint strings, and arbitrary error descriptions.
public enum WirelessIdentityTrace {
  public typealias Observer = @Sendable (Event) -> Void

  public enum Stage: String, Sendable, Codable {
    case attempt, identityTimerElapsed, identityDeadline, identityResult, identityCancellation
    case tcpConnect, socketRead, socketClose
    case initializationWrite, initializationHeader, initializationBody, initializationACK
    case openSessionDelay
    case openSessionWrite, openSessionHeader, openSessionData, openSessionFinalHeader, openSessionResponseBody
    case getDeviceInfoWrite, getDeviceInfoHeader, getDeviceInfoData, getDeviceInfoFinalHeader, getDeviceInfoResponseBody
    case deviceInfoValidation, xAppEventsRead, xAppAccess, xAppVersionRead, xAppVersionValidation
    case closeSessionWrite, closeSessionHeader, closeSessionData, closeSessionFinalHeader, closeSessionResponseBody
    case galleryModeWrite, galleryVersionRead, galleryVersionValidation, galleryVersionWrite
    case galleryCardBegin, galleryStorageWrite, galleryStorageRead, galleryStorageConfirmation
    case galleryOpen, galleryPreviewSetup, galleryModeStatus, gallerySelectedImages
    case galleryObjectListBegin, galleryObjectCount, galleryHandleList, galleryHandleValidation
    case galleryObjectInfo, galleryObjectInfoValidation, galleryCardSummary
    case sessionCleanup, otherCommand
  }

  public enum Action: String, Sendable, Codable {
    case waiting, completed, failed, readRequested, readCompleted, noData, endOfStream
  }

  public enum Failure: String, Sendable, Codable {
    case cancelled, outerDeadline, tcpSetupTimeout, transactionInactivity
    case localNetworkPermission, routeUnavailable, connectionLost, malformedData
    case authentication, peerMismatch, unsupported, unavailableStorage, rejected, other

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
        case .unavailableStorage: self = .unavailableStorage
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

  public struct GalleryCardSummary: Sendable, Codable, Equatable {
    public enum Status: String, Sendable, Codable { case available, unavailable }
    public let slot: UInt32
    public let totalHandles: Int?
    public let sampledJPEG: Int
    public let sampledRAF: Int
    public let sampledOther: Int
    public let status: Status
    public let sampledCount: Int

    init(slot: UInt32, totalHandles: Int?, sampledJPEG: Int, sampledRAF: Int, sampledOther: Int) {
      self.slot = slot
      self.totalHandles = totalHandles
      self.sampledJPEG = sampledJPEG
      self.sampledRAF = sampledRAF
      self.sampledOther = sampledOther
      status = totalHandles == nil ? .unavailable : .available
      sampledCount = sampledJPEG + sampledRAF + sampledOther
    }
  }

  public struct Event: Sendable, Codable, Equatable {
    public let stage: Stage
    public let action: Action
    public let bytes: Int?
    public let failure: Failure?
    public let responseCode: UInt16?
    public let galleryCard: GalleryCardSummary?
    public let gallerySlot: UInt32?

    public init(
      _ stage: Stage, _ action: Action, bytes: Int? = nil, failure: Failure? = nil,
      responseCode: UInt16? = nil, galleryCard: GalleryCardSummary? = nil, gallerySlot: UInt32? = nil
    ) {
      self.stage = stage
      self.action = action
      self.bytes = bytes.map { min(max($0, 0), 65_536) }
      self.failure = failure
      self.responseCode = responseCode
      self.galleryCard = galleryCard
      self.gallerySlot = gallerySlot.flatMap { (1...2).contains($0) ? $0 : nil }
    }
  }
}
