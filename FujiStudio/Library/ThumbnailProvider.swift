import FujiCameraCore
import Photos
import UIKit

/// Native image/cache boundary. A canceled request may still deliver a late callback.
@MainActor
protocol ThumbnailImageLoading: AnyObject {
    func request(sourceID: SourceID, pixelSize: CGSize, completion: @escaping @MainActor (UIImage?) -> Void) -> UUID
    func cancel(_ token: UUID)
    func cache(sourceIDs: [SourceID], pixelSize: CGSize)
    func invalidate(sourceIDs: Set<SourceID>)
}

/// A cell keeps its request until cancellation, including delivery after asset changes.
@MainActor
protocol GridThumbnailProviding: ThumbnailImageLoading {}

@MainActor
final class ThumbnailProvider: GridThumbnailProviding {
    private let loader: any ThumbnailImageLoading
    private struct Request {
        let sourceID: SourceID
        let pixelSize: CGSize
        let completion: @MainActor (UIImage?) -> Void
        var nativeToken: UUID? = nil
        var generation = UUID()
    }
    private var requests: [UUID: Request] = [:]

    init(loader: any ThumbnailImageLoading = PhotosThumbnailLoader()) { self.loader = loader }

    func request(sourceID: SourceID, pixelSize: CGSize, completion: @escaping @MainActor (UIImage?) -> Void) -> UUID {
        let token = UUID()
        requests[token] = Request(sourceID: sourceID, pixelSize: pixelSize, completion: completion)
        load(token)
        return token
    }
    func cancel(_ token: UUID) {
        if let request = requests.removeValue(forKey: token), let native = request.nativeToken { loader.cancel(native) }
    }
    func cache(sourceIDs: [SourceID], pixelSize: CGSize) { loader.cache(sourceIDs: sourceIDs, pixelSize: pixelSize) }
    func invalidate(sourceIDs: Set<SourceID>) {
        guard !sourceIDs.isEmpty else { return }
        loader.invalidate(sourceIDs: sourceIDs)
        let affected = requests.filter { sourceIDs.contains($0.value.sourceID) }.map(\.key)
        for token in affected { load(token) }
    }

    private func load(_ token: UUID) {
        guard var request = requests[token] else { return }
        let old = request.nativeToken
        request.nativeToken = nil; request.generation = UUID()
        requests[token] = request
        if let old { loader.cancel(old) }
        let generation = request.generation
        let native = loader.request(sourceID: request.sourceID, pixelSize: request.pixelSize) { [weak self] image in
            guard let current = self?.requests[token], current.generation == generation else { return }
            current.completion(image)
        }
        // A synchronous cache hit can reenter invalidation or cancellation before start returns.
        if var current = requests[token], current.generation == generation {
            current.nativeToken = native; requests[token] = current
        } else { loader.cancel(native) }
    }
}

@MainActor
private final class PhotosThumbnailLoader: ThumbnailImageLoading {
    private let manager = PHCachingImageManager()
    private var requests: [UUID: PHImageRequestID] = [:]
    private var cached: [SourceID: PHAsset] = [:]
    private var cachedSize = CGSize.zero
    private let options: PHImageRequestOptions = {
        let value = PHImageRequestOptions()
        value.isNetworkAccessAllowed = false
        value.deliveryMode = .opportunistic
        value.resizeMode = .fast
        value.version = .current
        return value
    }()
    func request(sourceID: SourceID, pixelSize: CGSize, completion: @escaping @MainActor (UIImage?) -> Void) -> UUID {
        let token = UUID()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [sourceID], options: nil).firstObject else {
            completion(nil); return token
        }
        let request = manager.requestImage(for: asset, targetSize: pixelSize, contentMode: .aspectFill, options: options) { [weak self] image, _ in
            Task { @MainActor [weak self] in
                guard self?.requests[token] != nil else { return }
                completion(image)
            }
        }
        requests[token] = request
        return token
    }
    func cancel(_ token: UUID) {
        if let id = requests.removeValue(forKey: token) { manager.cancelImageRequest(id) }
    }
    /// Controller supplies visible + UIKit prefetch IDs only. Cap speculative preheating.
    func cache(sourceIDs: [SourceID], pixelSize: CGSize) {
        let ids = Set(sourceIDs.prefix(120))
        if cachedSize != pixelSize {
            manager.stopCachingImages(for: Array(cached.values), targetSize: cachedSize, contentMode: .aspectFill, options: options)
            cached.removeAll(); cachedSize = pixelSize
        }
        let removed = cached.keys.filter { !ids.contains($0) }
        manager.stopCachingImages(for: removed.compactMap { cached[$0] }, targetSize: pixelSize, contentMode: .aspectFill, options: options)
        for id in removed { cached.removeValue(forKey: id) }
        let added = ids.subtracting(cached.keys)
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: Array(added), options: nil).enumerateObjects { asset, _, _ in assets.append(asset) }
        for asset in assets { cached[asset.localIdentifier] = asset }
        manager.startCachingImages(for: assets, targetSize: pixelSize, contentMode: .aspectFill, options: options)
    }

    func invalidate(sourceIDs: Set<SourceID>) {
        let stale = sourceIDs.compactMap { cached.removeValue(forKey: $0) }
        guard !stale.isEmpty else { return }
        manager.stopCachingImages(for: stale, targetSize: cachedSize, contentMode: .aspectFill, options: options)
        let wanted = Array(Set(cached.keys).union(stale.map(\.localIdentifier)))
        cache(sourceIDs: wanted, pixelSize: cachedSize)
    }
}
