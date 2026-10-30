import CoreLocation
import Foundation
import FujiCameraCore
import Photos
import UniformTypeIdentifiers

struct NativePhotoPairGateway: PhotoPairGateway {
    func access() async -> LibraryAccess { NativePhotoEditGateway.checkAccessValue() }
    func state(assetID: String) async throws -> PhotoPairAssetState? { try Self.snapshot(assetID) }

    func createPair(intent: PhotoPairIntent, rawURL: URL, jpegURL: URL,
                    onPlaceholder: @escaping @Sendable (String) -> Void) async throws -> String {
        guard PHAssetCreationRequest.supportsAssetResourceTypes([NSNumber(value: PHAssetResourceType.photo.rawValue),
            NSNumber(value: PHAssetResourceType.alternatePhoto.rawValue)]) else {
            throw PhotoLibraryWriteError.rejected(.invalidResource)
        }
        let outcome = PairTransactionOutcome()
        return try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                do {
                    guard try Self.snapshot(intent.source.id) == intent.originalState,
                          try NativePhotoEditGateway.matchesOriginal(NativePhotoEditGateway.asset(intent.source.id), source: intent.source) else {
                        throw ResourceError.resourceChanged
                    }
                    let albumChanges = try intent.originalState.albumIDs.map { id in
                        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject,
                              album.canPerform(.addContent), let change = PHAssetCollectionChangeRequest(for: album) else {
                            throw PhotoLibraryWriteError.invalidOutput("An original album is no longer writable.")
                        }
                        return change
                    }
                    let asset = PHAssetCreationRequest.forAsset()
                    let metadata = intent.originalState
                    asset.creationDate = metadata.captureDate
                    asset.location = metadata.location.map {
                        CLLocation(coordinate: .init(latitude: $0.latitude, longitude: $0.longitude), altitude: $0.altitude,
                            horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: metadata.captureDate ?? Date())
                    }
                    asset.isFavorite = metadata.isFavorite; asset.isHidden = metadata.isHidden
                    asset.caption = metadata.caption; asset.rating = PHAsset.Rating(rawValue: metadata.rating) ?? .unset
                    for keyword in metadata.keywords { asset.addKeyword(keyword) }
                    let jpeg = PHAssetResourceCreationOptions()
                    jpeg.originalFilename = intent.filename; jpeg.contentType = .jpeg; jpeg.shouldMoveFile = false
                    asset.addResource(with: .photo, fileURL: jpegURL, options: jpeg)
                    let raw = PHAssetResourceCreationOptions()
                    raw.originalFilename = intent.source.originalResources.raf.originalFilename
                    raw.contentType = UTType(intent.source.originalResources.raf.contentTypeIdentifier); raw.shouldMoveFile = false
                    asset.addResource(with: .alternatePhoto, fileURL: rawURL, options: raw)
                    asset.originalResourceChoice = .compressed
                    guard let placeholder = asset.placeholderForCreatedAsset else { throw PhotoLibraryWriteError.invalidOutput("Photos did not allocate the paired asset.") }
                    outcome.setID(placeholder.localIdentifier)
                    for change in albumChanges { change.addAssets([placeholder] as NSArray) }
                    onPlaceholder(placeholder.localIdentifier)
                } catch { outcome.setError(error) }
            } completionHandler: { success, error in
                // An exception-free block can still have created a pair before an album error.
                if outcome.error != nil {
                    continuation.resume(throwing: outcome.id == nil
                        ? PhotoLibraryWriteError.rejected(.invalidResource)
                        : PhotoLibraryWriteError.uncertain(.missingConfirmation))
                } else if !success { continuation.resume(throwing: PhotoLibraryWriteError.rejected(PhotoLibraryWriter.failure(error.map { $0 as NSError }))) }
                else if error == nil, let id = outcome.id { continuation.resume(returning: id) }
                else { continuation.resume(throwing: PhotoLibraryWriteError.uncertain(.missingConfirmation)) }
            }
        }
    }
    func matchingAssets(filename: String) async throws -> [String] {
        try await NativePhotoWriteGateway().assets(filename: filename).map(\.assetID)
    }
    func removeOriginal(intent: PhotoPairIntent, verified: PhotoPairVerified) async throws {
        let outcome = PairTransactionOutcome()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                do {
                    guard try Self.snapshot(intent.source.id) == intent.originalState,
                          try Self.snapshot(verified.source.id) == verified.state else { throw ResourceError.resourceChanged }
                    let original = try NativePhotoEditGateway.asset(intent.source.id)
                    let pair = try NativePhotoEditGateway.asset(verified.source.id)
                    guard original.canPerform(.delete), try NativePhotoEditGateway.matchesOriginal(original, source: intent.source),
                          try NativePhotoEditGateway.matchesOriginal(pair, source: verified.source) else { throw ResourceError.resourceChanged }
                    PHAssetChangeRequest.deleteAssets([original] as NSArray)
                } catch { outcome.setError(error) }
            } completionHandler: { success, error in
                if let caught = outcome.error { continuation.resume(throwing: caught) }
                else if !success || error != nil { continuation.resume(throwing: PhotoLibraryWriteError.uncertain(PhotoLibraryWriter.failure(error.map { $0 as NSError }))) }
                else { continuation.resume() }
            }
        }
    }

    private static func snapshot(_ id: String) throws -> PhotoPairAssetState? {
        let access = NativePhotoEditGateway.checkAccessValue()
        guard access == .full || access == .limited else { throw PhotoLibraryWriteError.authorization(access) }
        if let error = PHPhotoLibrary.shared().unavailabilityReason { throw PhotoLibraryWriteError.lookupFailed(error.localizedDescription) }
        let options = NativePhotoWriteGateway.recoveryFetchOptions()
        options.prefetchAssetExtendedMetadata = true
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: options).firstObject else { return nil }
        let albums = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        var ids: [String] = []
        albums.enumerateObjects { album, _, _ in
            if album.assetCollectionSubtype == .albumRegular, album.canPerform(.addContent) { ids.append(album.localIdentifier) }
        }
        return PhotoPairAssetState(assetID: id, modificationDate: asset.modificationDate, captureDate: asset.creationDate,
            location: asset.location.map { .init(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, altitude: $0.altitude) },
            isFavorite: asset.isFavorite, isHidden: asset.isHidden, caption: asset.extendedMetadata.caption,
            rating: asset.rating.rawValue, keywords: asset.extendedMetadata.keywords.sorted(), albumIDs: ids.sorted())
    }
}

private final class PairTransactionOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var failure: Error?
    var id: String? { lock.withLock { value } }
    var error: Error? { lock.withLock { failure } }
    func setID(_ id: String) { lock.withLock { value = id } }
    func setError(_ error: Error) { lock.withLock { failure = error } }
}
