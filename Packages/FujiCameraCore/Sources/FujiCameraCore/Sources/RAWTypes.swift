import Foundation

public typealias SourceID = String

public enum ResourceRole: String, Sendable, Hashable, Codable {
  case primaryOriginal, alternateOriginal, adjusted
}
public enum ResourceFormat: String, Sendable, Hashable, Codable { case raf, jpeg, other }

public struct ResourceToken: Sendable, Hashable, Codable {
  public let assetID: SourceID
  public let role: ResourceRole
  public let contentTypeIdentifier: String
  public let format: ResourceFormat
  public let originalFilename: String
  public let discriminator: String
  public var sourceRevision: String = ""
  public var byteCount: Int64? = nil
  public init(
    assetID: SourceID, role: ResourceRole, contentTypeIdentifier: String, format: ResourceFormat,
    originalFilename: String, discriminator: String, sourceRevision: String = "",
    byteCount: Int64? = nil
  ) {
    self.assetID = assetID
    self.role = role
    self.contentTypeIdentifier = contentTypeIdentifier
    self.format = format
    self.originalFilename = originalFilename
    self.discriminator = discriminator
    self.sourceRevision = sourceRevision
    self.byteCount = byteCount
  }

}

public struct OriginalResources: Sendable, Equatable, Codable {
  public let raf: ResourceToken
  public let jpeg: ResourceToken?
  public init(raf: ResourceToken, jpeg: ResourceToken? = nil) {
    self.raf = raf
    self.jpeg = jpeg
  }

}

public struct PhotoLocation: Sendable, Equatable, Codable {
  public let latitude: Double
  public let longitude: Double
  public let altitude: Double
  public init(latitude: Double, longitude: Double, altitude: Double) {
    self.latitude = latitude
    self.longitude = longitude
    self.altitude = altitude
  }

}

public enum RAWCompatibility: Sendable, Equatable, Codable {
  case unknown
  case supported(model: String)
  case incompatible(model: String)
}

public struct PhotoSource: Sendable, Equatable, Identifiable, Codable {
  public let id: SourceID
  public let originalResources: OriginalResources
  public let captureDate: Date?
  public let location: PhotoLocation?
  public let resourceRevision: String
  public var compatibility: RAWCompatibility = .unknown
  public init(
    id: SourceID, originalResources: OriginalResources, captureDate: Date? = nil,
    location: PhotoLocation? = nil, resourceRevision: String,
    compatibility: RAWCompatibility = .unknown
  ) {
    self.id = id
    self.originalResources = originalResources
    self.captureDate = captureDate
    self.location = location
    self.resourceRevision = resourceRevision
    self.compatibility = compatibility
  }

}

public struct LocalResource: Sendable, Equatable {
  public let token: ResourceToken
  public let fileURL: URL
  public let checksum: String
  public init(token: ResourceToken, fileURL: URL, checksum: String) {
    self.token = token
    self.fileURL = fileURL
    self.checksum = checksum
  }

}

public struct LibraryChange: Sendable, Equatable {
  public let changedIDs: Set<SourceID>
  public let removedIDs: Set<SourceID>
  public let accessScopeChanged: Bool
  public init(changedIDs: Set<SourceID>, removedIDs: Set<SourceID>, accessScopeChanged: Bool) {
    self.changedIDs = changedIDs
    self.removedIDs = removedIDs
    self.accessScopeChanged = accessScopeChanged
  }

}

public enum LibraryAccess: String, Sendable {
  case notDetermined, full, limited, denied, restricted
}

public enum ResourceError: Error, Sendable, Equatable {
  case noOriginalRAF
  case ambiguousOriginalRAF
  case ambiguousOriginalJPEG
  case inaccessibleAsset(SourceID)
  case resourceChanged
  case authorization(LibraryAccess)
  case retrievalFailed(String)
  case insufficientStorage
  case invalidRAF(String)
  case incompatibleCamera(String)
  case checksumMismatch
}

public struct PixelSize: Sendable, Equatable, Hashable, Codable {
  public let width: Int
  public let height: Int
  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }

}

public enum RAFCompression: UInt32, Sendable, Equatable, Codable {
  case uncompressed = 0
  case lossless = 2
  case lossy = 3
}

public struct RAWMetadata: Sendable, Equatable, Codable {
  public let cameraModel: String
  public let containerGeometry: PixelSize
  public let recordedGeometry: PixelSize
  public let recordedAspect: PixelSize
  public let cropTop: Int
  public let cropLeft: Int
  public let orientation: Int
  public let compression: RAFCompression?
  public let bitDepth: Int?
  public let rafVersion: String?
  public let captureDynamicRange: Int?
  public init(
    cameraModel: String, containerGeometry: PixelSize, recordedGeometry: PixelSize,
    recordedAspect: PixelSize, cropTop: Int, cropLeft: Int, orientation: Int,
    compression: RAFCompression? = nil, bitDepth: Int? = nil, rafVersion: String? = nil,
    captureDynamicRange: Int? = nil
  ) {
    self.cameraModel = cameraModel
    self.containerGeometry = containerGeometry
    self.recordedGeometry = recordedGeometry
    self.recordedAspect = recordedAspect
    self.cropTop = cropTop
    self.cropLeft = cropLeft
    self.orientation = orientation
    self.compression = compression
    self.bitDepth = bitDepth
    self.rafVersion = rafVersion
    self.captureDynamicRange = captureDynamicRange.flatMap { [100, 200, 400].contains($0) ? $0 : nil }
  }

  /// Every supported capture permits DR100 when its original DR cannot be established.
  public func effectiveDynamicRange(for requested: Int) -> Int {
    let capture = captureDynamicRange.flatMap { [100, 200, 400].contains($0) ? $0 : nil } ?? 100
    return min(requested, capture)
  }
}

public struct PreparedRAW: Sendable, Equatable {
  public let fileURL: URL
  public let sha256: String
  public let sourceID: SourceID
  public let sourceRevision: String
  public let metadata: RAWMetadata
  public init(
    fileURL: URL, sha256: String, sourceID: SourceID, sourceRevision: String, metadata: RAWMetadata
  ) {
    self.fileURL = fileURL
    self.sha256 = sha256
    self.sourceID = sourceID
    self.sourceRevision = sourceRevision
    self.metadata = metadata
  }

}
