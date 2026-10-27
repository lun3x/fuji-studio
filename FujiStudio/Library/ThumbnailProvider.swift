import Photos
import UIKit

/// UI-only read side. Images never enter rendering/conversion service boundaries.
@MainActor
protocol GridThumbnailProviding: AnyObject {
    func request(sourceID: SourceID, pixelSize: CGSize, completion: @escaping @MainActor (UIImage?) -> Void) -> UUID
    func cancel(_ token: UUID)
    func cache(sourceIDs: [SourceID], pixelSize: CGSize)
}

@MainActor
final class ThumbnailProvider: GridThumbnailProviding {
    private let manager = PHCachingImageManager()
    private var requests: [UUID: PHImageRequestID] = [:]
    private var cached: [SourceID: PHAsset] = [:]
    private var cachedSize = CGSize.zero
    private let options: PHImageRequestOptions = {
        let value = PHImageRequestOptions()
        value.isNetworkAccessAllowed = false
        value.deliveryMode = .opportunistic
        value.resizeMode = .fast
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
}
