import CoreLocation
import CryptoKit
import Foundation
import FujiCameraCore
import Photos
import UniformTypeIdentifiers

struct NativePhotoImportGateway: PhotoImportGateway {
    private let staging: ImportStagingStore
    private let creation: any PhotoImportCreationBackend

    init(staging: ImportStagingStore, creation: any PhotoImportCreationBackend = PhotoKitImportCreation()) {
        self.staging = staging
        self.creation = creation
    }

    /// Call only from an explicit Import or Manage Photos action. Creation and recovery
    /// check current read/write authorization without displaying a prompt.
    static func requestReadWriteAccess() async -> LibraryAccess {
        PhotoLibraryReader.access(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    func create(_ capture: ValidatedCapture,
                onPlaceholder: @escaping @Sendable (String) throws -> Void) async -> PhotoImportOutcome {
        let access = creation.access
        guard access == .full || access == .limited else { return .rejected(.authorization) }
        guard creation.isAvailable, !Task.isCancelled else { return .rejected(.unavailable) }

        let request: PhotoImportCreation
        do {
            request = try creationRequest(for: capture)
        } catch {
            let failure = error as NSError
            if (failure.domain == NSCocoaErrorDomain && failure.code == CocoaError.fileWriteOutOfSpace.rawValue)
                || (failure.domain == NSPOSIXErrorDomain && failure.code == Int(ENOSPC)) {
                return .rejected(.storage)
            }
            return .rejected(.invalidResource)
        }
        guard creation.supports(request.resources.map(\.type)) else { return .rejected(.invalidResource) }
        guard !Task.isCancelled else { return .rejected(.unavailable) }

        let transaction = PhotoImportTransaction()
        return await withCheckedContinuation { continuation in
            // Once issued, settlement belongs to PhotoKit even when the calling task is cancelled.
            creation.performCreation(request) { id in
                guard !id.isEmpty else { return }
                do {
                    try onPlaceholder(id)
                    transaction.record(id: id, persisted: true)
                } catch {
                    transaction.record(id: id, persisted: false)
                }
            } completion: { success, error in
                continuation.resume(returning: transaction.outcome(success: success, error: error))
            }
        }
    }

    func isDefinitelyAbsent(assetID: String) async -> Bool {
        guard Self.readableAccess() == .full else { return false }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: Self.fetchOptions())
        return assets.count == 0 && Self.readableAccess() == .full
    }

    func inspect(assetID: String) async throws -> ImportedAssetInspection {
        try Task.checkCancellation()
        guard let access = Self.readableAccess() else { return .unavailable }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: Self.fetchOptions())
        guard let asset = assets.firstObject else {
            return access == .full && Self.readableAccess() == .full ? .absent : .unavailable
        }
        let originals = Self.originalResources(for: asset)
        guard !originals.isEmpty else { return .foundUnreadable }

        var fingerprints: [ImportedResourceFingerprint] = []
        for resource in originals {
            guard !Task.isCancelled, let fingerprint = try? await Self.read(resource) else {
                return .foundUnreadable
            }
            fingerprints.append(fingerprint)
        }
        guard !Task.isCancelled, Self.readableAccess() == access else { return .foundUnreadable }
        return .found(.init(assetID: asset.localIdentifier, originals: fingerprints))
    }

    func candidates(for capture: ValidatedCapture) async throws -> [String] {
        guard Self.readableAccess() != nil else { throw PhotoImportFailure.unavailable }
        let date = capture.metadata.creationDate
        let expectedNames = Set(capture.originals.map(\.originalFilename))
        let options = Self.fetchOptions()
        // creationDate is the assigned capture date. Allow date precision differences in Photos.
        // A filter hit is only a lead, and an empty result never proves absence.
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
            date.addingTimeInterval(-1) as NSDate, date.addingTimeInterval(1) as NSDate)
        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var ids: [String] = []
        for index in 0..<assets.count {
            try Task.checkCancellation()
            let asset = assets.object(at: index)
            if Self.originalResources(for: asset).contains(where: { resource in
                resource.filename.map(expectedNames.contains) == true
            }) {
                ids.append(asset.localIdentifier)
            }
        }
        guard Self.readableAccess() != nil else { throw PhotoImportFailure.unavailable }
        return ids
    }

    private func creationRequest(for capture: ValidatedCapture) throws -> PhotoImportCreation {
        try capture.selection.validateForOriginalImport()
        let pair = capture.selection.policy == .pair
        let roles: [ImportOriginalRole] = pair ? [.raf, .jpeg] : [.raf]
        guard capture.originals.map(\.role) == roles else { throw PhotoImportFailure.invalidResource }

        let resources = try capture.originals.reversed().map { original in
            let type: PHAssetResourceType = pair && original.role == .raf ? .alternatePhoto : .photo
            let url = try staging.fileURL(for: original)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size.flatMap(UInt64.init(exactly:)) == original.byteCount else {
                throw PhotoImportFailure.invalidResource
            }
            return PhotoImportCreation.Resource(type: type, format: original.role,
                                                filename: original.originalFilename, fileURL: url)
        }
        return .init(resources: resources, metadata: capture.metadata, prefersJPEG: pair)
    }

    private static func readableAccess() -> LibraryAccess? {
        let access = PhotoLibraryReader.access(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        guard access == .full || access == .limited, PHPhotoLibrary.shared().unavailabilityReason == nil else {
            return nil
        }
        return access
    }

    private static func fetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        return options
    }

    private static func originalResources(for asset: PHAsset) -> [PHAssetResource] {
        PHAssetResource.assetResources(for: asset).filter { resource in
            switch resource.type {
            case .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo, .adjustmentData,
                 .adjustmentBasePhoto, .adjustmentBaseVideo, .adjustmentBasePairedVideo:
                // These describe the edit pipeline. The original resource list is independent.
                false
            default:
                // Include extra original roles and unknown resources so they cannot silently
                // disappear from the exact comparison.
                true
            }
        }
    }

    private static func read(_ resource: PHAssetResource) async throws -> ImportedResourceFingerprint {
        let role: ImportedResourceRole = switch resource.type {
        case .photo: .primary
        case .alternatePhoto: .alternate
        default: .other
        }
        let format: ImportOriginalRole?
        if resource.contentType.conforms(to: .jpeg) {
            format = .jpeg
        } else if let raf = UTType("com.fuji.raw-image"), resource.contentType.conforms(to: raf) {
            format = .raf
        } else {
            format = nil
        }
        guard let filename = resource.filename, !filename.isEmpty else { throw PhotoImportFailure.unavailable }
        let digest = PhotoImportResourceDigest()
        let options = PHAssetResourceRequestOptions()
        // Reconciliation can run with only the camera network reachable. Cloud-only data
        // stays unresolved until the original is available on the device.
        options.isNetworkAccessAllowed = false
        return try await withCheckedThrowingContinuation { continuation in
            PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: digest.append) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(with: Result {
                        let (count, sha256) = try digest.finish()
                        return .init(role: role, format: format, originalFilename: filename, byteCount: count, sha256: sha256)
                    })
                }
            }
        }
    }
}

/// The native boundary has only one operation. It cannot replace, edit, or delete assets.
protocol PhotoImportCreationBackend: Sendable {
    var access: LibraryAccess { get }
    var isAvailable: Bool { get }
    func supports(_ types: [PHAssetResourceType]) -> Bool
    func performCreation(_ request: PhotoImportCreation, onPlaceholder: @escaping @Sendable (String) -> Void,
                         completion: @escaping @Sendable (Bool, Error?) -> Void)
}

struct PhotoImportCreation: Sendable {
    struct Resource: Sendable {
        let type: PHAssetResourceType
        let format: ImportOriginalRole
        let filename: String
        let fileURL: URL
        var shouldMoveFile: Bool { false }
    }

    let resources: [Resource]
    let metadata: ImportCaptureMetadata
    let prefersJPEG: Bool
}

struct PhotoKitImportCreation: PhotoImportCreationBackend {
    var access: LibraryAccess { PhotoLibraryReader.access(PHPhotoLibrary.authorizationStatus(for: .readWrite)) }
    var isAvailable: Bool { PHPhotoLibrary.shared().unavailabilityReason == nil }

    func supports(_ types: [PHAssetResourceType]) -> Bool {
        PHAssetCreationRequest.supportsAssetResourceTypes(types.map { NSNumber(value: $0.rawValue) })
    }

    func performCreation(_ request: PhotoImportCreation, onPlaceholder: @escaping @Sendable (String) -> Void,
                         completion: @escaping @Sendable (Bool, Error?) -> Void) {
        PHPhotoLibrary.shared().performChanges {
            let asset = PHAssetCreationRequest.forAsset()
            asset.creationDate = request.metadata.creationDate
            asset.location = request.metadata.location.map {
                CLLocation(coordinate: .init(latitude: $0.latitude, longitude: $0.longitude),
                           altitude: $0.altitude ?? 0, horizontalAccuracy: -1, verticalAccuracy: -1,
                           timestamp: request.metadata.creationDate)
            }
            for resource in request.resources {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = resource.filename
                options.contentType = resource.format == .jpeg ? .jpeg : UTType("com.fuji.raw-image")
                options.shouldMoveFile = resource.shouldMoveFile
                asset.addResource(with: resource.type, fileURL: resource.fileURL, options: options)
            }
            if request.prefersJPEG { asset.originalResourceChoice = .compressed }
            if let id = asset.placeholderForCreatedAsset?.localIdentifier { onPlaceholder(id) }
        } completionHandler: { success, error in
            completion(success, error)
        }
    }
}

private final class PhotoImportTransaction: @unchecked Sendable {
    private let lock = NSLock()
    private var placeholder: (id: String, persisted: Bool)?

    func record(id: String, persisted: Bool) {
        lock.withLock { placeholder = (id, persisted) }
    }

    func outcome(success: Bool, error: Error?) -> PhotoImportOutcome {
        lock.withLock {
            if success, error == nil, let placeholder, placeholder.persisted {
                return .submitted(assetID: placeholder.id)
            }
            let systemError = error.map { error in
                let nsError = error as NSError
                return "\(nsError.domain) (\(nsError.code))"
            }
            return .uncertain(assetID: placeholder?.id, systemError: systemError)
        }
    }
}

private final class PhotoImportResourceDigest: @unchecked Sendable {
    private let lock = NSLock()
    private var hash = SHA256()
    private var count: UInt64 = 0
    private var overflow = false

    func append(_ chunk: Data) {
        lock.withLock {
            let (total, didOverflow) = count.addingReportingOverflow(UInt64(chunk.count))
            overflow = overflow || didOverflow
            count = total
            hash.update(data: chunk)
        }
    }

    func finish() throws -> (UInt64, String) {
        try lock.withLock {
            guard count > 0, !overflow else { throw PhotoImportFailure.unavailable }
            return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }
}
