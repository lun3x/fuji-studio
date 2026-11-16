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
    case galleryOpen, galleryPreviewSetup, galleryModeStatus, gallerySelectedImages, galleryJPEGRAWFilter
    case galleryObjectListBegin, galleryObjectCount, galleryHandleList, galleryHandleValidation
    case galleryOriginalModeRead, galleryOriginalModeWrite, galleryOriginalModeConfirmation
    case galleryOriginalModeRestore, galleryOriginalModeRestoreUnconfirmed
    case galleryObjectInfo, galleryObjectInfoValidation, galleryCardSummary
    case pairSelection, pairControlRead, pairPartialObject, pairFileTransfer, pairFileValidation
    case pairValidation, pairStoragePrepare, pairPublication, pairCleanup
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
        case .unsupportedProtocol, .unsupportedFirmware, .originalSizeUnavailable: self = .unsupported
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
    public enum Status: String, Sendable, Codable { case scanning, available, unavailable }
    public let slot: UInt32
    public let totalHandles: Int?
    public private(set) var jpegCount: Int
    public private(set) var rafCount: Int
    public private(set) var otherCount: Int
    public private(set) var status: Status
    public private(set) var scannedCount: Int

    init(slot: UInt32, totalHandles: Int?, jpegCount: Int, rafCount: Int, otherCount: Int) {
      self.slot = slot
      self.totalHandles = totalHandles
      self.jpegCount = jpegCount
      self.rafCount = rafCount
      self.otherCount = otherCount
      scannedCount = jpegCount + rafCount + otherCount
      status = Self.status(totalHandles, scannedCount)
    }

    mutating func record(_ format: WirelessObjectFormat) {
      switch format {
      case .jpeg: jpegCount += 1
      case .raf: rafCount += 1
      case .other: otherCount += 1
      }
      scannedCount += 1
      status = Self.status(totalHandles, scannedCount)
    }

    private static func status(_ total: Int?, _ scanned: Int) -> Status {
      guard let total else { return .unavailable }
      return total == scanned ? .available : .scanning
    }
  }

  public enum GalleryOriginalMode: UInt32, Sendable, Codable {
    case mode0 = 0
    case mode1 = 1
    case original = 2
  }

  public enum PairRole: String, Sendable, Codable { case raf, jpeg }

  public enum OriginalControl: Sendable, Codable, Equatable {
    case reported(UInt32)
    case unsupported
  }

  public struct PairFile: Sendable, Codable, Equatable {
    public let role: PairRole
    public let expectedBytes: UInt64
    public let receivedBytes: UInt64?
    public let originalControl: OriginalControl?

    public init(role: PairRole, expectedBytes: UInt64, receivedBytes: UInt64? = nil,
                originalControl: OriginalControl? = nil) {
      self.role = role
      self.expectedBytes = expectedBytes
      self.receivedBytes = receivedBytes
      self.originalControl = originalControl
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
    public let pairFile: PairFile?
    public let galleryOriginalMode: GalleryOriginalMode?

    public init(
      _ stage: Stage, _ action: Action, bytes: Int? = nil, failure: Failure? = nil,
      responseCode: UInt16? = nil, galleryCard: GalleryCardSummary? = nil, gallerySlot: UInt32? = nil,
      pairFile: PairFile? = nil, galleryOriginalMode: GalleryOriginalMode? = nil
    ) {
      self.stage = stage
      self.action = action
      self.bytes = bytes.map { min(max($0, 0), 65_536) }
      self.failure = failure
      self.responseCode = responseCode
      self.galleryCard = galleryCard
      self.pairFile = pairFile
      self.galleryOriginalMode = galleryOriginalMode
      self.gallerySlot = gallerySlot.flatMap { (1...2).contains($0) ? $0 : nil }
    }
  }
}
