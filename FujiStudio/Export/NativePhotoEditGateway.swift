import Foundation
import Photos
import FujiCameraCore

/// PhotoKit reference objects stay inside this boundary; input/output have one owner.
struct NativePhotoEditGateway: PhotoEditGateway {
    func access() async -> LibraryAccess { Self.checkAccessValue() }

    func prepare(source: PhotoSource) async throws -> any PhotoEditingSession {
        let asset = try Self.asset(source.id)
        guard asset.canPerform(.content), try Self.matchesOriginal(asset, source: source) else {
            throw PhotoLibraryWriteError.invalidOutput("This original is no longer available for editing.")
        }
        let input = try await Self.input(asset)
        try Task.checkCancellation()
        let current = try Self.asset(source.id)
        guard current.modificationDate == asset.modificationDate,
              try Self.matchesOriginal(current, source: source) else {
            throw PhotoLibraryWriteError.invalidOutput("The photo changed while preparing the edit. Export again.")
        }
        return NativePhotoEditingSession(asset: current, source: source,
            output: PHContentEditingOutput(contentEditingInput: input.value))
    }

    func currentAdjustment(assetID: String) async throws -> PhotoEditAdjustment? {
        let asset = try Self.asset(assetID)
        let input = try await Self.input(asset)
        let current = try Self.asset(assetID)
        guard current.modificationDate == asset.modificationDate else { throw ResourceError.resourceChanged }
        guard let data = input.value.adjustmentData,
              data.formatIdentifier == PhotoEditAdjustment.formatIdentifier,
              data.formatVersion == PhotoEditAdjustment.formatVersion else { return nil }
        return try JSONDecoder().decode(PhotoEditAdjustment.self, from: data.data)
    }

    static func checkAccessValue() -> LibraryAccess {
        PhotoLibraryReader.access(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    static func asset(_ id: String) throws -> PHAsset {
        let access = checkAccessValue()
        guard access == .full || access == .limited else { throw PhotoLibraryWriteError.authorization(access) }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw PhotoLibraryWriteError.invalidOutput("The original photo is not accessible in Photos.")
        }
        return asset
    }

    static func matchesOriginal(_ asset: PHAsset, source: PhotoSource) throws -> Bool {
        let originals = try RawResourceSelector.select(PhotoLibraryReader.descriptors(asset).map(\.token))
        return originals == source.originalResources && originals.raf.sourceRevision == source.resourceRevision
    }

    private static func input(_ asset: PHAsset) async throws -> PhotoEditingInputBox {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        // We only inspect adjustment data or render afresh from the immutable RAW.
        // Never use Photos' input pixels to apply an additional recipe.
        options.canHandleAdjustmentData = { _ in true }
        return try await withCheckedThrowingContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, info in
                if let error = info[PHContentEditingInputErrorKey] as? NSError {
                    continuation.resume(throwing: PhotoLibraryWriteError.lookupFailed(error.localizedDescription))
                } else if let input {
                    continuation.resume(returning: PhotoEditingInputBox(input))
                } else {
                    continuation.resume(throwing: PhotoLibraryWriteError.invalidOutput("Photos could not prepare this photo for editing."))
                }
            }
        }
    }
}

private final class PhotoEditingInputBox: @unchecked Sendable {
    let value: PHContentEditingInput
    init(_ value: PHContentEditingInput) { self.value = value }
}

private final class NativePhotoEditingSession: PhotoEditingSession, @unchecked Sendable {
    let assetID: String
    let renderedContentURL: URL
    private let asset: PHAsset
    private let source: PhotoSource
    private let output: PHContentEditingOutput

    init(asset: PHAsset, source: PhotoSource, output: PHContentEditingOutput) {
        self.asset = asset; self.source = source; self.output = output
        assetID = asset.localIdentifier; renderedContentURL = output.renderedContentURL
    }

    func commit(adjustment: PhotoEditAdjustment, completion: @escaping @Sendable (Bool, NSError?) -> Void) throws {
        let current = try NativePhotoEditGateway.asset(assetID)
        guard current.modificationDate == asset.modificationDate, current.canPerform(.content),
              try NativePhotoEditGateway.matchesOriginal(current, source: source) else {
            throw PhotoLibraryWriteError.invalidOutput("The photo changed before the edit could be saved. Export again.")
        }
        output.adjustmentData = PHAdjustmentData(formatIdentifier: PhotoEditAdjustment.formatIdentifier,
            formatVersion: PhotoEditAdjustment.formatVersion, data: try JSONEncoder().encode(adjustment))
        PHPhotoLibrary.shared().performChanges({ [self] in
            PHAssetChangeRequest(for: asset).contentEditingOutput = output
        }) { success, error in completion(success, error.map { $0 as NSError }) }
    }
}
