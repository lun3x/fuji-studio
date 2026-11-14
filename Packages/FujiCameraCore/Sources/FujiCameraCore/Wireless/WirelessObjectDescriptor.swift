import Foundation

public enum WirelessObjectFormat: Equatable, Hashable, Codable, Sendable {
  case raf
  case jpeg
  case other(UInt16)
}

/// Camera-reported original metadata frozen before selection. Capture dates retain their
/// PTP offset (or absence of an offset). Directory is present only when the peer reports it.
public struct WirelessObjectDescriptor: Equatable, Hashable, Codable, Sendable {
  public let cameraID: WirelessCameraID
  public let sessionID: UUID
  public let storageID: UInt32
  public let handle: UInt32
  public let directory: String?
  public let filename: String
  public let format: WirelessObjectFormat
  public let byteLength: UInt64
  public let captureDate: String?
  public let dimensions: PixelSize?
  public let orientation: Int?
  public let reportedStorageID: UInt32?
  public let hasThumbnail: Bool

  public init(
    cameraID: WirelessCameraID, sessionID: UUID, storageID: UInt32, handle: UInt32,
    directory: String? = nil, filename: String, format: WirelessObjectFormat, byteLength: UInt64,
    captureDate: String? = nil, dimensions: PixelSize? = nil, orientation: Int? = nil,
    reportedStorageID: UInt32? = nil, hasThumbnail: Bool = false
  ) {
    self.cameraID = cameraID
    self.sessionID = sessionID
    self.storageID = storageID
    self.handle = handle
    self.directory = directory
    self.filename = filename
    self.format = format
    self.byteLength = byteLength
    self.captureDate = captureDate
    self.dimensions = dimensions
    self.orientation = orientation
    self.reportedStorageID = reportedStorageID
    self.hasThumbnail = hasThumbnail
  }

  /// A candidate match still requires uniqueness within the re-enumerated inventory.
  public func matchesOriginal(_ other: Self) -> Bool {
    cameraID == other.cameraID && storageID == other.storageID
      && reportedStorageID == other.reportedStorageID && directory == other.directory
      && filename == other.filename && format == other.format && byteLength == other.byteLength
      && captureDate == other.captureDate && dimensions == other.dimensions
      && orientation == other.orientation
  }
}

public struct WirelessStorageInventory: Equatable, Sendable {
  public enum Completeness: Equatable, Sendable {
    case pending
    case complete
    case unavailable
  }

  public var storage: [UInt32: Completeness]
  public var rawExposure: WirelessRAWExposure

  public init(storage: [UInt32: Completeness] = [:], rawExposure: WirelessRAWExposure = .unknown) {
    self.storage = storage
    self.rawExposure = rawExposure
  }

  public mutating func apply(_ batch: WirelessInventoryBatch) {
    storage.merge(batch.storageChanges) { _, latest in latest }
    if let exposure = batch.rawExposure { rawExposure = exposure }
  }
}

public struct WirelessInventoryBatch: Equatable, Sendable {
  public let objects: [WirelessObjectDescriptor]
  public let storageChanges: [UInt32: WirelessStorageInventory.Completeness]
  public let rawExposure: WirelessRAWExposure?

  public init(
    objects: [WirelessObjectDescriptor],
    storageChanges: [UInt32: WirelessStorageInventory.Completeness] = [:],
    rawExposure: WirelessRAWExposure? = nil
  ) {
    self.objects = objects
    self.storageChanges = storageChanges
    self.rawExposure = rawExposure
  }
}
