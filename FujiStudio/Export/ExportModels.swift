import FujiCameraCore
import Foundation

enum AssetAvailability: String, Sendable, Codable, Equatable {
    case available, inaccessible, missing, deleted
}

/// A Photos operation identifies one deliberate exported item, independently of camera attempts.
struct SavedVersion: Sendable, Codable, Equatable, Identifiable {
    let id: UUID
    let sourceID: SourceID
    let outputAssetID: String
    let recipeSnapshot: RecipeSnapshot
    let operationID: UUID
    let exportedAt: Date
    let jpeg: CameraJPEG
    var availability: AssetAvailability

    var width: Int { jpeg.width }
    var height: Int { jpeg.height }
    var orientation: Int { jpeg.orientation }
}

/// No empty reconciliation lookup can turn submitted/unknown into a definitive rejection.
/// Persist the attempt's time before submitting, so crash recovery retains the export label.
enum SaveSubmission: Sendable, Codable, Equatable {
    case notSubmitted
    case submitted(at: Date)
    case unknown(at: Date)
    case definitivelyRejected(at: Date, reason: String)

    var attemptedAt: Date? {
        switch self {
        case .notSubmitted: nil
        case .submitted(let at), .unknown(let at), .definitivelyRejected(let at, _): at
        }
    }
}

struct PendingSave: Sendable, Codable, Equatable {
    let operationID: UUID
    let filename: String
    let jpeg: CameraJPEG
    var placeholderID: String?
    var submission: SaveSubmission

    init(operationID: UUID, jpeg: CameraJPEG, placeholderID: String? = nil,
         submission: SaveSubmission = .notSubmitted) {
        self.operationID = operationID
        filename = "FujiStudio-\(operationID.uuidString).jpg"
        self.jpeg = jpeg
        self.placeholderID = placeholderID
        self.submission = submission
    }
}

enum ExportFailure: Sendable, Codable, Equatable {
    case preparation(String), unsupportedSettings(String), transport(String)
    case unsupportedSource, authorization, inaccessible, insufficientStorage, unresolvedSave(String)
}

enum ExportItemState: Sendable, Codable, Equatable {
    case queued, preparing, converting
    case pendingSave(PendingSave)
    case saved(UUID)
    case failed(ExportFailure)
    case cancelled, unprocessed
    case unresolved(PendingSave)
}

struct ExportItem: Sendable, Codable, Equatable, Identifiable {
    let source: PhotoSource
    let operationID: UUID
    var state: ExportItemState = .queued
    var id: UUID { operationID }
}

enum ExportJobState: String, Sendable, Codable, Equatable {
    case queued, preparing, converting, pendingSave, saved, failed, cancelled, unprocessed, unresolved, paused
}

/// Submission fields and ordered sources are frozen; only progress and outcomes change.
struct ExportJob: Sendable, Codable, Equatable, Identifiable {
    let id: UUID
    let submittedAt: Date
    let recipeSnapshot: RecipeSnapshot
    var items: [ExportItem]
    var state: ExportJobState
}
