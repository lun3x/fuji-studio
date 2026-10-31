import FujiCameraCore
import CoreLocation
import Foundation
import Photos
import UniformTypeIdentifiers

/// PhotoKit objects remain within a change block; no PHAsset crosses the service boundary.
protocol PhotoAssetCreating: AnyObject {
    var placeholderID: String? { get }
    func setCreationDate(_ date: Date)
    func setLocation(_ location: PhotoLocation)
    func addResource(type: PHAssetResourceType, fileURL: URL, options: PHAssetResourceCreationOptions)
}

protocol PhotoAssetFactory: Sendable {
    func makeAsset() -> any PhotoAssetCreating
}

struct PhotoSavedResource: Sendable {
    let assetID: String
    let filename: String
    let photosGeometry: PixelSize?
}

/// The only external boundary: real PhotoKit transactions and metadata-only fetches.
protocol PhotoWriteGateway: Sendable {
    func access() async -> LibraryAccess
    func performChanges(_ changes: @escaping @Sendable (any PhotoAssetFactory) -> Void,
                        completion: @escaping @Sendable (Bool, NSError?) -> Void)
    func asset(id: String) async throws -> PhotoSavedResource?
    func assets(filename: String) async throws -> [PhotoSavedResource]
}

struct PhotoLibraryWriter: PhotoLibraryWriting {
    private let gateway: any PhotoWriteGateway
    private let editor: PhotoLibraryEditor
    private let pairer: PhotoLibraryPairer
    init(gateway: any PhotoWriteGateway = NativePhotoWriteGateway(), editor: PhotoLibraryEditor = PhotoLibraryEditor(),
         pairer: PhotoLibraryPairer = PhotoLibraryPairer()) {
        self.gateway = gateway; self.editor = editor; self.pairer = pairer
    }

    func saveJPEG(_ request: PhotoSaveRequest,
                  onPlaceholder: @escaping @Sendable (String) -> Void) async throws -> SavedAsset {
        try Task.checkCancellation()
        if let edit = request.originalEdit {
            if edit.source.originalResources.jpeg == nil {
                return try await pairer.saveJPEG(request, edit: edit, onPlaceholder: onPlaceholder)
            }
            return try await editor.saveJPEG(request, edit: edit, onPlaceholder: onPlaceholder)
        }
        let access = await gateway.access()
        guard access == .full || access == .limited else { throw PhotoLibraryWriteError.authorization(access) }
        let url = request.jpeg.fileURL
        guard url.isFileURL, request.jpeg.width > 0, request.jpeg.height > 0,
              (1...8).contains(request.jpeg.orientation),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isReadableKey]),
              values.isRegularFile == true, values.isReadable == true, (values.fileSize ?? 0) > 0 else {
            throw PhotoLibraryWriteError.invalidOutput("The pinned camera JPEG is unavailable or has invalid geometry.")
        }
        try Task.checkCancellation()
        let placeholder = PhotoSavePlaceholder()
        // Once submitted, cancellation must wait for PhotoKit's real completion. There is no
        // cancellable performChanges API, and releasing the pinned file early risks a duplicate.
        return try await withCheckedThrowingContinuation { continuation in
            gateway.performChanges { factory in
                let asset = factory.makeAsset()
                if let date = request.captureDate { asset.setCreationDate(date) }
                if let location = request.location { asset.setLocation(location) }
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = request.filename
                options.contentType = .jpeg
                options.shouldMoveFile = false
                asset.addResource(type: .photo, fileURL: url, options: options)
                if let id = asset.placeholderID {
                    placeholder.set(id)
                    onPlaceholder(id)
                }
            } completion: { success, error in
                guard success else {
                    continuation.resume(throwing: PhotoLibraryWriteError.rejected(Self.failure(error)))
                    return
                }
                guard error == nil, let id = placeholder.value else {
                    continuation.resume(throwing: PhotoLibraryWriteError.uncertain(error.map(Self.failure) ?? .missingConfirmation))
                    return
                }
                continuation.resume(returning: SavedAsset(assetID: id, operationID: request.operationID, photosGeometry: nil))
            }
        }
    }

    func findExport(operationID: UUID, knownAssetID: String?, originalAssetID: String?) async throws -> SaveLookup {
        try Task.checkCancellation()
        if let originalAssetID {
            if try await pairer.hasIntent(operationID) {
                return try await pairer.findExport(operationID: operationID, sourceID: originalAssetID, knownAssetID: knownAssetID)
            }
            return try await editor.findExport(operationID: operationID, sourceID: originalAssetID)
        }
        let initialAccess = await gateway.access()
        guard initialAccess == .full || initialAccess == .limited else { return .inaccessible }
        let filename = "FujiStudio-\(operationID.uuidString).jpg"
        if let knownAssetID, let asset = try await gateway.asset(id: knownAssetID), asset.filename == filename {
            let currentAccess = await gateway.access()
            guard currentAccess == .full || currentAccess == .limited else { return .inaccessible }
            return .found(saved(asset, operationID: operationID))
        }
        let matches = try await gateway.assets(filename: filename).filter { $0.filename == filename }
        let finalAccess = await gateway.access()
        guard finalAccess == .full || finalAccess == .limited else { return .inaccessible }
        guard matches.count <= 1 else { throw PhotoLibraryWriteError.ambiguousOperation(operationID) }
        if let asset = matches.first { return .found(saved(asset, operationID: operationID)) }
        // Full access before and after a complete metadata scan is required even for this
        // observation of absence. The durable export coordinator decides what happens next.
        return initialAccess == .full && finalAccess == .full ? .notFound : .inaccessible
    }

    func completeReplacement(operationID: UUID, assetID: String) async throws -> SavedAsset {
        try await pairer.completeReplacement(operationID: operationID, assetID: assetID)
    }
    func completeReplacements(_ assets: [SavedAsset], allowingPreviousEdits: Bool,
                              beforeRemoval: @escaping @Sendable () async throws -> Void) async throws -> [SavedAsset] {
        try await pairer.completeReplacements(assets, allowingPreviousEdits: allowingPreviousEdits, beforeRemoval: beforeRemoval)
    }
    func sourceReplacements() async throws -> [SourceID: SourceID] { try await pairer.sourceReplacements() }

    private func saved(_ resource: PhotoSavedResource, operationID: UUID) -> SavedAsset {
        SavedAsset(assetID: resource.assetID, operationID: operationID, photosGeometry: resource.photosGeometry)
    }

    static func failure(_ error: NSError?) -> PhotoSaveFailure {
        guard let error else { return .missingConfirmation }
        if error.domain == PHPhotosErrorDomain {
            switch error.code {
            case PHPhotosError.notEnoughSpace.rawValue: return .insufficientStorage
            case PHPhotosError.accessUserDenied.rawValue, PHPhotosError.accessRestricted.rawValue: return .authorization
            case PHPhotosError.invalidResource.rawValue, PHPhotosError.missingResource.rawValue: return .invalidResource
            default: break
            }
        }
        if (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError) ||
            (error.domain == NSPOSIXErrorDomain && error.code == ENOSPC) { return .insufficientStorage }
        return .transaction(domain: error.domain, code: error.code)
    }
}

private final class PhotoSavePlaceholder: @unchecked Sendable {
    private let lock = NSLock()
    private var id: String?
    var value: String? { lock.withLock { id } }
    func set(_ id: String) { lock.withLock { self.id = id } }
}

struct NativePhotoWriteGateway: PhotoWriteGateway {
    private let library = PHPhotoLibrary.shared()
    func access() async -> LibraryAccess {
        PhotoLibraryReader.access(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }
    func performChanges(_ changes: @escaping @Sendable (any PhotoAssetFactory) -> Void,
                        completion: @escaping @Sendable (Bool, NSError?) -> Void) {
        library.performChanges({ changes(NativePhotoAssetFactory()) }) { success, error in
            completion(success, error.map { $0 as NSError })
        }
    }
    func asset(id: String) async throws -> PhotoSavedResource? {
        try checkAvailability()
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: Self.recoveryFetchOptions())
        let result = fetched.firstObject.flatMap { resource($0) }
        try checkAvailability()
        return result
    }
    func assets(filename: String) async throws -> [PhotoSavedResource] {
        try checkAvailability()
        let fetched = PHAsset.fetchAssets(with: .image, options: Self.recoveryFetchOptions())
        var matches: [PhotoSavedResource] = []
        for index in 0..<fetched.count {
            try Task.checkCancellation()
            if let candidate = resource(fetched.object(at: index), filename: filename) { matches.append(candidate) }
        }
        try checkAvailability()
        return matches
    }
    static func recoveryFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        options.fetchLimit = 0
        return options
    }
    private func checkAvailability() throws {
        if let error = library.unavailabilityReason { throw PhotoLibraryWriteError.lookupFailed(error.localizedDescription) }
    }
    private func resource(_ asset: PHAsset, filename: String? = nil) -> PhotoSavedResource? {
        // Only original JPEG resource metadata identifies our independent creation. No requests
        // for image/RAW data, adjusted resources, timestamp matching or source association.
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: {
            $0.type == .photo && $0.contentType.conforms(to: .jpeg) &&
            $0.filename != nil && (filename == nil || $0.filename == filename)
        }), let name = resource.filename else { return nil }
        let geometry = asset.pixelWidth > 0 && asset.pixelHeight > 0 ? PixelSize(width: asset.pixelWidth, height: asset.pixelHeight) : nil
        return PhotoSavedResource(assetID: asset.localIdentifier, filename: name, photosGeometry: geometry)
    }
}

private struct NativePhotoAssetFactory: PhotoAssetFactory {
    func makeAsset() -> any PhotoAssetCreating { NativeNewPhotoAsset(request: PHAssetCreationRequest.forAsset()) }
}

private final class NativeNewPhotoAsset: PhotoAssetCreating {
    private let request: PHAssetCreationRequest
    init(request: PHAssetCreationRequest) { self.request = request }
    var placeholderID: String? { request.placeholderForCreatedAsset?.localIdentifier }
    func setCreationDate(_ date: Date) { request.creationDate = date }
    func setLocation(_ location: PhotoLocation) {
        request.location = CLLocation(coordinate: .init(latitude: location.latitude, longitude: location.longitude),
            altitude: location.altitude, horizontalAccuracy: -1, verticalAccuracy: -1, timestamp: Date())
    }
    func addResource(type: PHAssetResourceType, fileURL: URL, options: PHAssetResourceCreationOptions) {
        request.addResource(with: type, fileURL: fileURL, options: options)
    }
}
