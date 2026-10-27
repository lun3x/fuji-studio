import Foundation

typealias SourceID = String

enum ResourceRole: String, Sendable, Hashable, Codable { case primaryOriginal, alternateOriginal, adjusted }
enum ResourceFormat: String, Sendable, Hashable, Codable { case raf, jpeg, other }

struct ResourceToken: Sendable, Hashable, Codable {
    let assetID: SourceID
    let role: ResourceRole
    let contentTypeIdentifier: String
    let format: ResourceFormat
    let originalFilename: String
    let discriminator: String
    var sourceRevision: String = ""
    var byteCount: Int64? = nil
}

struct OriginalResources: Sendable, Equatable, Codable {
    let raf: ResourceToken
    let jpeg: ResourceToken?
}

struct PhotoLocation: Sendable, Equatable, Codable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
}

enum RAWCompatibility: Sendable, Equatable, Codable { case unknown, xt5, incompatible(model: String) }

struct PhotoSource: Sendable, Equatable, Identifiable, Codable {
    let id: SourceID
    let originalResources: OriginalResources
    let captureDate: Date?
    let location: PhotoLocation?
    let resourceRevision: String
    var compatibility: RAWCompatibility = .unknown
}

struct LocalResource: Sendable, Equatable {
    let token: ResourceToken
    let fileURL: URL
    let checksum: String
}

struct LibraryChange: Sendable, Equatable {
    let changedIDs: Set<SourceID>
    let removedIDs: Set<SourceID>
    let accessScopeChanged: Bool
}

enum LibraryAccess: String, Sendable { case notDetermined, full, limited, denied, restricted }

enum ResourceError: Error, Sendable, Equatable {
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

struct PixelSize: Sendable, Equatable, Hashable {
    let width: Int
    let height: Int
}

struct RAWMetadata: Sendable, Equatable {
    let cameraModel: String
    let containerGeometry: PixelSize
    let recordedGeometry: PixelSize
    let recordedAspect: PixelSize
    let cropTop: Int
    let cropLeft: Int
    let orientation: Int
}

struct PreparedRAW: Sendable, Equatable {
    let fileURL: URL
    let sha256: String
    let sourceID: SourceID
    let sourceRevision: String
    let metadata: RAWMetadata
}
