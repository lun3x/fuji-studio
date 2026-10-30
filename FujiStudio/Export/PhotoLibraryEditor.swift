import FujiCameraCore
import Foundation

struct PhotoOriginalEdit: Sendable {
    let source: PhotoSource
    let recipe: RecipeSnapshot
}

/// Identifies the current rendition, not merely the asset containing it.
struct PhotoEditAdjustment: Codable, Sendable, Equatable {
    static let formatIdentifier = "com.lun3x.FujiStudio.recipe"
    static let formatVersion = "1"
    let operationID: UUID
    let sourceID: SourceID
    let recipe: RecipeSnapshot
}

protocol PhotoEditReading: Sendable {
    func currentAdjustment(assetID: String) async throws -> PhotoEditAdjustment?
}

protocol PhotoEditingSession: AnyObject, Sendable {
    var assetID: String { get }
    var renderedContentURL: URL { get }
    /// Throws only before submission. Every submitted transaction reports via completion.
    func commit(adjustment: PhotoEditAdjustment,
                completion: @escaping @Sendable (Bool, NSError?) -> Void) throws
}

protocol PhotoEditGateway: PhotoEditReading {
    func access() async -> LibraryAccess
    func prepare(source: PhotoSource) async throws -> any PhotoEditingSession
}

struct PhotoLibraryEditor: Sendable {
    private let gateway: any PhotoEditGateway
    init(gateway: any PhotoEditGateway = NativePhotoEditGateway()) { self.gateway = gateway }

    func saveJPEG(_ request: PhotoSaveRequest, edit: PhotoOriginalEdit,
                  onPlaceholder: @escaping @Sendable (String) -> Void) async throws -> SavedAsset {
        try Task.checkCancellation()
        let access = await gateway.access()
        guard access == .full || access == .limited else { throw PhotoLibraryWriteError.authorization(access) }
        guard request.jpeg.sourceID == edit.source.id,
              request.jpeg.sourceRevision == edit.source.resourceRevision,
              request.jpeg.settingsDigest == edit.recipe.settingsDigest else {
            throw PhotoLibraryWriteError.invalidOutput("The exported JPEG does not match the original and recipe.")
        }
        let session: any PhotoEditingSession
        do { session = try await gateway.prepare(source: edit.source) }
        catch { throw Self.preflightFailure(error) }
        guard session.assetID == edit.source.id else {
            throw PhotoLibraryWriteError.invalidOutput("Photos prepared a different original.")
        }
        defer { try? FileManager.default.removeItem(at: session.renderedContentURL) }
        try Task.checkCancellation()
        try PhotoEditJPEG.write(request.jpeg, to: session.renderedContentURL)
        try Task.checkCancellation()
        let adjustment = PhotoEditAdjustment(operationID: request.operationID, sourceID: edit.source.id, recipe: edit.recipe)
        // Once submitted, retain both the session and rendered file until real completion.
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.commit(adjustment: adjustment) { success, error in
                    guard success else {
                        continuation.resume(throwing: PhotoLibraryWriteError.rejected(PhotoLibraryWriter.failure(error)))
                        return
                    }
                    if let error {
                        continuation.resume(throwing: PhotoLibraryWriteError.uncertain(PhotoLibraryWriter.failure(error)))
                    } else {
                        continuation.resume(returning: SavedAsset(assetID: session.assetID,
                            operationID: request.operationID, photosGeometry: nil))
                    }
                }
                onPlaceholder(session.assetID)
            } catch { continuation.resume(throwing: Self.preflightFailure(error)) }
        }
    }

    private static func preflightFailure(_ error: Error) -> Error {
        if error is CancellationError { return error }
        switch error {
        case PhotoLibraryWriteError.authorization, PhotoLibraryWriteError.invalidOutput, PhotoLibraryWriteError.rejected:
            return error
        default:
            return PhotoLibraryWriteError.invalidOutput("Photos could not prepare the original: \(error.localizedDescription)")
        }
    }

    func findExport(operationID: UUID, sourceID: String) async throws -> SaveLookup {
        try Task.checkCancellation()
        let access = await gateway.access()
        guard access == .full || access == .limited else { return .inaccessible }
        let adjustment = try await gateway.currentAdjustment(assetID: sourceID)
        let finalAccess = await gateway.access()
        guard finalAccess == .full || finalAccess == .limited else { return .inaccessible }
        guard adjustment?.operationID == operationID, adjustment?.sourceID == sourceID else { return .notFound }
        return .found(SavedAsset(assetID: sourceID, operationID: operationID, photosGeometry: nil))
    }
}
