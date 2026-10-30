import FujiCameraCore
import Foundation

/// The caller owns and pins jpeg.fileURL until the actual Photos transaction completes.
/// operationID identifies this deliberate Photos export, not CameraJPEG.operationID.
struct PhotoSaveRequest: Sendable {
    let jpeg: CameraJPEG
    let operationID: UUID
    let captureDate: Date?
    let location: PhotoLocation?
    var originalEdit: PhotoOriginalEdit? = nil

    var filename: String { "FujiStudio-\(operationID.uuidString).jpg" }
}

struct SavedAsset: Sendable, Equatable {
    let assetID: String
    let operationID: UUID
    /// Observed current Photos pixel dimensions, when fetched. These may describe an edited
    /// presentation, and never replace the pinned CameraJPEG's encoded geometry/orientation.
    let photosGeometry: PixelSize?
}

enum SaveLookup: Sendable, Equatable {
    case found(SavedAsset), needsReplacementCleanup(SavedAsset), notFound, inaccessible
}

enum PhotoSaveFailure: Sendable, Equatable {
    case authorization, insufficientStorage, invalidResource, missingConfirmation
    case transaction(domain: String, code: Int)
}

enum PhotoLibraryWriteError: Error, Sendable, Equatable {
    /// These preflight failures have not submitted a Photos transaction.
    case authorization(LibraryAccess), invalidOutput(String)
    /// PhotoKit's completion reported failure; a placeholder is not a saved asset.
    case rejected(PhotoSaveFailure)
    /// Submission succeeded without sufficient confirmation; reconcile instead of retrying.
    case uncertain(PhotoSaveFailure)
    case lookupFailed(String), ambiguousOperation(UUID)
}

protocol PhotoLibraryWriting: Sendable {
    func saveJPEG(_ request: PhotoSaveRequest,
                  onPlaceholder: @escaping @Sendable (String) -> Void) async throws -> SavedAsset
    /// Absence is an observation, never authorization to resubmit an uncertain transaction.
    func findExport(operationID: UUID, knownAssetID: String?, originalAssetID: String?) async throws -> SaveLookup
    func completeReplacement(operationID: UUID, assetID: String) async throws -> SavedAsset
    func sourceReplacements() async throws -> [SourceID: SourceID]
}

extension PhotoLibraryWriting {
    func completeReplacement(operationID: UUID, assetID: String) async throws -> SavedAsset {
        throw PhotoLibraryWriteError.invalidOutput("This writer does not create RAW+JPEG pairs.")
    }
    func sourceReplacements() async throws -> [SourceID: SourceID] { [:] }
}
