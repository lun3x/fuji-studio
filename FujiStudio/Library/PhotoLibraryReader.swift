import Foundation
import Photos
import UniformTypeIdentifiers
import CryptoKit

protocol PhotoLibraryReading: Sendable {
    func requestAccess() async -> LibraryAccess
    func sources() async -> AsyncThrowingStream<[PhotoSource], Error>
    func allEligibleSources() async throws -> [PhotoSource]
    func source(id: SourceID) async throws -> PhotoSource
    func resources(assetID: String) async throws -> [ResourceToken]
    func changes() async -> AsyncStream<LibraryChange>
    func materialize(_ resource: ResourceToken, progress: @escaping @Sendable (Double) -> Void) async throws -> LocalResource
}

extension PhotoLibraryReading {
    func allEligibleSources() async throws -> [PhotoSource] {
        try Task.checkCancellation()
        var result: [PhotoSource] = []
        for try await batch in await sources() { result.append(contentsOf: batch) }
        try Task.checkCancellation()
        return result
    }
}

/// Value boundary for PhotoKit. Role and content type jointly identify originals.
struct PhotoResourceDescriptor: Sendable {
    let assetID: String
    let resourceType: Int
    let contentTypeIdentifier: String
    let filename: String
    var byteCount: Int64? = nil
    var revision: String = ""

    var token: ResourceToken {
        let role: ResourceRole = switch PHAssetResourceType(rawValue: resourceType) {
        case .photo: .primaryOriginal
        case .alternatePhoto: .alternateOriginal
        default: .adjusted
        }
        let type = UTType(contentTypeIdentifier)
        let format: ResourceFormat
        if contentTypeIdentifier == "com.fuji.raw-image" || UTType("com.fuji.raw-image").map({ type?.conforms(to: $0) == true }) == true {
            format = .raf
        } else if type?.conforms(to: .jpeg) == true {
            format = .jpeg
        } else {
            format = .other
        }
        return ResourceToken(assetID: assetID, role: role, contentTypeIdentifier: contentTypeIdentifier,
                             format: format, originalFilename: filename,
                             discriminator: "\(resourceType)|\(contentTypeIdentifier)|\(filename)",
                             sourceRevision: revision, byteCount: byteCount)
    }
}

/// A lock protects request registration, file writes, and exactly-once completion.
/// PhotoKit callbacks use an arbitrary serial queue; cancellation may race any callback.
final class ResourceFileTransfer: @unchecked Sendable {
    typealias Start = (@escaping @Sendable (Data) -> Void, @escaping @Sendable (Error?) -> Void) -> (@Sendable () -> Void)
    let fileURL: URL
    private let token: ResourceToken
    private let lock = NSLock()
    private var handle: FileHandle?
    private var continuation: CheckedContinuation<LocalResource, Error>?
    private var cancelRequest: (@Sendable () -> Void)?
    private var terminal: Result<LocalResource, Error>?
    private var abortRequest = false
    private var hash = SHA256()

    init(token: ResourceToken) throws {
        self.token = token
        let suffix = token.format == .raf ? "RAF" : token.format == .jpeg ? "JPG" : "resource"
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("FujiStudio-\(UUID().uuidString).\(suffix)")
        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw ResourceError.insufficientStorage
        }
        do { handle = try FileHandle(forWritingTo: fileURL) }
        catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw Self.fileError(error)
        }
    }

    deinit {
        try? handle?.close()
        if terminal == nil { try? FileManager.default.removeItem(at: fileURL) }
    }

    // Start the PhotoKit request on the caller's actor; only Sendable data callbacks escape it.
    func run(start: Start, isolation: isolated (any Actor)? = #isolation) async throws -> LocalResource {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldStart = lock.withLock {
                    if let terminal { continuation.resume(with: terminal); return false }
                    self.continuation = continuation
                    return true
                }
                guard shouldStart else { return }
                let cancel = start({ [self] in receive($0) }, { [self] in finish($0) })
                let shouldCancel = lock.withLock {
                    cancelRequest = terminal == nil ? cancel : nil
                    return abortRequest
                }
                if shouldCancel { cancel() }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        let request = lock.withLock {
            guard terminal == nil else { return Optional<@Sendable () -> Void>.none }
            abortRequest = true
            let request = cancelRequest
            completeLocked(.failure(CancellationError()))
            return request
        }
        request?()
    }

    private func receive(_ data: Data) {
        let request: (@Sendable () -> Void)? = lock.withLock {
            guard terminal == nil else { return nil }
            do {
                try handle?.write(contentsOf: data)
                hash.update(data: data)
                return nil
            } catch {
                abortRequest = true
                let request = cancelRequest
                completeLocked(.failure(Self.fileError(error)))
                return request
            }
        }
        request?()
    }

    private func finish(_ error: Error?) {
        lock.withLock {
            guard terminal == nil else { return }
            if let error { completeLocked(.failure(error)); return }
            do {
                try handle?.synchronize()
                let checksum = hash.finalize().map { String(format: "%02x", $0) }.joined()
                completeLocked(.success(LocalResource(token: token, fileURL: fileURL, checksum: checksum)))
            } catch { completeLocked(.failure(Self.fileError(error))) }
        }
    }

    private func completeLocked(_ result: Result<LocalResource, Error>) {
        terminal = result
        try? handle?.close()
        handle = nil
        cancelRequest = nil
        if case .failure = result { try? FileManager.default.removeItem(at: fileURL) }
        continuation?.resume(with: result)
        continuation = nil
    }

    static func fileError(_ error: Error) -> ResourceError {
        let error = error as NSError
        if (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError) ||
            (error.domain == NSPOSIXErrorDomain && error.code == ENOSPC) {
            return .insufficientStorage
        }
        return .retrievalFailed(error.localizedDescription)
    }
}

actor PhotoLibraryReader: PhotoLibraryReading {
    private let library = PHPhotoLibrary.shared()
    private let observer = LibraryObserver()
    private var observing = false

    deinit { library.unregisterChangeObserver(observer) }

    func requestAccess() async -> LibraryAccess {
        Self.access(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    func sources() async -> AsyncThrowingStream<[PhotoSource], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let fetched = try authorizedAssets()
                    var discovery = PhotoSourceDiscovery(count: fetched.count, assetAt: { fetched.object(at: $0) },
                                                          captureDate: { $0.creationDate }, identifier: { $0.localIdentifier },
                                                          source: { try self.makeSource($0) })
                    while let batch = try discovery.nextBatch() {
                        continuation.yield(batch)
                        await Task.yield()
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func source(id: SourceID) async throws -> PhotoSource { try makeSource(asset(id)) }

    func resources(assetID: String) async throws -> [ResourceToken] {
        let asset = try asset(assetID)
        return descriptors(asset).map(\.token)
    }

    func changes() async -> AsyncStream<LibraryChange> {
        if !observing {
            observer.start()
            library.register(observer)
            observing = true
        }
        return observer.stream()
    }

    func materialize(_ resource: ResourceToken, progress: @escaping @Sendable (Double) -> Void) async throws -> LocalResource {
        try Task.checkCancellation()
        let asset = try asset(resource.assetID)
        let all = PHAssetResource.assetResources(for: asset)
        // Build descriptors from this exact snapshot; PhotoKit array order is not an identity.
        let current = descriptors(asset, resources: all)
        let matches = current.indices.filter { current[$0].token.discriminator == resource.discriminator }
        guard matches.count == 1, let index = matches.first,
              resource.sourceRevision == current[index].revision else {
            throw ResourceError.resourceChanged
        }
        let transfer = try ResourceFileTransfer(token: resource)
        let manager = PHAssetResourceManager.default()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { progress(max(0, min(1, $0))) }
        let result = try await transfer.run { data, done in
            let id = manager.requestData(for: all[index], options: options, dataReceivedHandler: data) { error in
                done(error.map { ResourceFileTransfer.fileError($0) })
            }
            return { manager.cancelDataRequest(id) }
        }
        do { try Task.checkCancellation() }
        catch {
            try? FileManager.default.removeItem(at: result.fileURL)
            throw error
        }
        progress(1)
        return result
    }

    private func authorizedAssets() throws -> PHFetchResult<PHAsset> {
        try checkAccess()
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(with: .image, options: options)
    }

    private func checkAccess() throws {
        let access = Self.access(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        guard access == .full || access == .limited else { throw ResourceError.authorization(access) }
    }

    private func asset(_ id: String) throws -> PHAsset {
        try checkAccess()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw ResourceError.inaccessibleAsset(id)
        }
        return asset
    }

    private func descriptors(_ asset: PHAsset, resources supplied: [PHAssetResource]? = nil) -> [PhotoResourceDescriptor] {
        let resources = supplied ?? PHAssetResource.assetResources(for: asset)
        let identities = resources.map { "\($0.type.rawValue)|\($0.contentType.identifier)|\($0.filename ?? "")" }.sorted().joined(separator: "\n")
        let revision = SHA256.hash(data: Data("\(asset.modificationDate?.timeIntervalSince1970 ?? 0)|\(identities)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return resources.map {
            PhotoResourceDescriptor(assetID: asset.localIdentifier, resourceType: $0.type.rawValue,
                                    contentTypeIdentifier: $0.contentType.identifier, filename: $0.filename ?? "",
                                    byteCount: $0.dataSize.map(Int64.init), revision: revision)
        }
    }

    private func makeSource(_ asset: PHAsset) throws -> PhotoSource {
        let tokens = descriptors(asset).map(\.token)
        let originals = try RawResourceSelector.select(tokens)
        return PhotoSource(id: asset.localIdentifier, originalResources: originals,
                           captureDate: asset.creationDate,
                           location: asset.location.map { PhotoLocation(latitude: $0.coordinate.latitude,
                                                                        longitude: $0.coordinate.longitude, altitude: $0.altitude) },
                           resourceRevision: originals.raf.sourceRevision)
    }

    static func access(_ status: PHAuthorizationStatus) -> LibraryAccess {
        switch status {
        case .authorized: .full
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .restricted
        }
    }
}

/// PhotoKit owns the callback queue. A lock keeps each subscriber and fetch snapshot consistent.
private final class LibraryObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var fetch: PHFetchResult<PHAsset>?
    private var access: LibraryAccess = .notDetermined
    private var subscribers: [UUID: AsyncStream<LibraryChange>.Continuation] = [:]

    func start() {
        lock.withLock {
            fetch = PHAsset.fetchAssets(with: .image, options: nil)
            access = PhotoLibraryReader.access(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        }
    }

    func stream() -> AsyncStream<LibraryChange> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { subscribers[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock { self?.subscribers.removeValue(forKey: id) }
            }
        }
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        lock.withLock {
            guard let fetch else { return }
            let nextAccess = PhotoLibraryReader.access(PHPhotoLibrary.authorizationStatus(for: .readWrite))
            var changed = Set<SourceID>(), removed = Set<SourceID>()
            if let details = changeInstance.changeDetails(for: fetch) {
                let after = details.fetchResultAfterChanges
                let beforeIDs = Set((0..<fetch.count).map { fetch.object(at: $0).localIdentifier })
                let afterIDs = Set((0..<after.count).map { after.object(at: $0).localIdentifier })
                removed = beforeIDs.subtracting(afterIDs)
                changed.formUnion(afterIDs.subtracting(beforeIDs))
                if details.hasIncrementalChanges { changed.formUnion(details.changedObjects.map(\.localIdentifier)) }
                else { changed.formUnion(afterIDs) }
                self.fetch = after
            }
            let scope = nextAccess != access || (nextAccess == .limited && (!changed.isEmpty || !removed.isEmpty))
            access = nextAccess
            let event = LibraryChange(changedIDs: changed, removedIDs: removed, accessScopeChanged: scope)
            for subscriber in subscribers.values { subscriber.yield(event) }
        }
    }
}
