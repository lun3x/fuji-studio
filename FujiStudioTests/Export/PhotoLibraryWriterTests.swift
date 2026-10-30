@testable import FujiCameraCore
import CryptoKit
import Foundation
import Photos
import Testing
import UniformTypeIdentifiers
@testable import FujiStudio

struct PhotoLibraryWriterTests {
    // Catches source mutation, re-encoding/moving the pinned file, and using the camera attempt UUID.
    @Test func savesCameraBytesAsNewAssetWithSourceDate() async throws {
        let f = try WriterFixture(); defer { f.remove() }
        let gateway = FakePhotoWriteGateway()
        let writer: any PhotoLibraryWriting = PhotoLibraryWriter(gateway: gateway)
        let events = WriterEvents()
        let saved = try await writer.saveJPEG(f.request()) { events.append("placeholder:\($0)") }
        events.append("saved")
        let asset = try #require(gateway.assets.first)
        #expect(gateway.assets.count == 1)
        #expect(asset.date == f.date)
        #expect(asset.location == f.location)
        #expect(asset.resources.count == 1)
        let resource = try #require(asset.resources.first)
        #expect(resource.type == .photo)
        #expect(resource.url == f.jpeg.fileURL)
        #expect(resource.filename == "FujiStudio-11111111-2222-3333-4444-555555555555.jpg")
        #expect(resource.contentType == .jpeg)
        #expect(resource.shouldMoveFile == false)
        #expect(resource.sha256 == f.hash)
        #expect(try Data(contentsOf: f.jpeg.fileURL) == f.bytes)
        #expect(saved.assetID == "synthetic-new")
        #expect(saved.operationID == f.operationID)
        #expect(saved.photosGeometry == nil)
        #expect(events.values == ["placeholder:synthetic-new", "saved"])
    }

    // Catches inventing Date() or a zero location instead of retaining PhotoKit defaults.
    @Test func absentSourceMetadataLeavesSystemDefaults() async throws {
        let f = try WriterFixture(); defer { f.remove() }
        let gateway = FakePhotoWriteGateway()
        _ = try await PhotoLibraryWriter(gateway: gateway).saveJPEG(f.request(metadata: false)) { _ in }
        #expect(gateway.assets.first?.dateAssignments == 0)
        #expect(gateway.assets.first?.locationAssignments == 0)
    }

    // Catches treating a placeholder as confirmation when the transaction actually failed.
    @Test func failedSaveIsTypedRejectionEvenAfterPlaceholder() async throws {
        let f = try WriterFixture(); defer { f.remove() }
        let gateway = FakePhotoWriteGateway()
        gateway.outcome = (false, NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.notEnoughSpace.rawValue))
        let events = WriterEvents()
        await #expect(throws: PhotoLibraryWriteError.rejected(.insufficientStorage)) {
            _ = try await PhotoLibraryWriter(gateway: gateway).saveJPEG(f.request()) { events.append($0) }
        }
        #expect(events.values == ["synthetic-new"])
    }

    // Catches reporting success without a usable confirmed output identity.
    @Test func successfulTransactionWithoutPlaceholderIsUncertain() async throws {
        let f = try WriterFixture(); defer { f.remove() }
        let gateway = FakePhotoWriteGateway(); gateway.placeholder = nil
        await #expect(throws: PhotoLibraryWriteError.uncertain(.missingConfirmation)) {
            _ = try await PhotoLibraryWriter(gateway: gateway).saveJPEG(f.request()) { _ in }
        }
    }

    // Catches cancellation racing performChanges and prematurely releasing the engine's pinned file.
    @Test func cancellationWaitsForActualTransactionOutcome() async throws {
        for success in [true, false] {
            let f = try WriterFixture(); defer { f.remove() }
            let gateway = FakePhotoWriteGateway(); gateway.deferCompletion = true
            let events = WriterEvents()
            let task = Task {
                do {
                    let result = try await PhotoLibraryWriter(gateway: gateway).saveJPEG(f.request()) { _ in }
                    events.append("saved")
                    return Result<SavedAsset, Error>.success(result)
                } catch { events.append("failed"); return .failure(error) }
            }
            await gateway.waitForSubmission()
            task.cancel()
            await Task.yield()
            #expect(events.values.isEmpty)
            gateway.complete(success: success, error: success ? nil : NSError(domain: PHPhotosErrorDomain, code: 3302))
            switch await task.value {
            case .success: #expect(success)
            case .failure(let error):
                #expect(!success)
                #expect(error as? PhotoLibraryWriteError == .rejected(.invalidResource))
            }
        }
    }

    // Catches unauthorized or missing-file requests ever entering a Photos transaction.
    @Test func authorizationAndInvalidFileFailBeforeSubmission() async throws {
        let f = try WriterFixture(); defer { f.remove() }
        let gateway = FakePhotoWriteGateway(); gateway.accesses = [.denied]
        await #expect(throws: PhotoLibraryWriteError.authorization(.denied)) {
            _ = try await PhotoLibraryWriter(gateway: gateway).saveJPEG(f.request()) { _ in }
        }
        gateway.accesses = [.full]; f.remove()
        await #expect(throws: PhotoLibraryWriteError.self) {
            _ = try await PhotoLibraryWriter(gateway: gateway).saveJPEG(f.request()) { _ in }
        }
        #expect(gateway.assets.isEmpty)
    }

    // Catches using timestamps, substring filenames, or stale known IDs to guess source relationships.
    @Test func exactFilenameRecoveryFallsBackAfterWrongKnownIdentity() async throws {
        let f = try WriterFixture(); defer { f.remove() }
        let gateway = FakePhotoWriteGateway()
        gateway.known = .init(assetID: "wrong-operation", filename: "FujiStudio-other.jpg", photosGeometry: .init(width: 1, height: 1))
        gateway.matches = [.init(assetID: "correct-output", filename: "FujiStudio-11111111-2222-3333-4444-555555555555.jpg", photosGeometry: .init(width: 7728, height: 5152))]
        let lookup = try await PhotoLibraryWriter(gateway: gateway).findExport(operationID: f.operationID, knownAssetID: "known", originalAssetID: nil)
        #expect(lookup == .found(.init(assetID: "correct-output", operationID: f.operationID, photosGeometry: .init(width: 7728, height: 5152))))
        #expect(gateway.lookups == ["id:known", "filename:FujiStudio-11111111-2222-3333-4444-555555555555.jpg"])
        #expect(gateway.assets.isEmpty)
    }

    // Catches needlessly scanning the library after recovering the exact known asset.
    @Test func knownExactAssetWinsBeforeFilenameScan() async throws {
        let f = try WriterFixture(); defer { f.remove() }
        let gateway = FakePhotoWriteGateway(); gateway.accesses = [.limited]
        gateway.known = .init(assetID: "known", filename: "FujiStudio-11111111-2222-3333-4444-555555555555.jpg", photosGeometry: .init(width: 7728, height: 5152))
        let lookup = try await PhotoLibraryWriter(gateway: gateway).findExport(operationID: f.operationID, knownAssetID: "known", originalAssetID: nil)
        #expect(lookup == .found(.init(assetID: "known", operationID: f.operationID, photosGeometry: .init(width: 7728, height: 5152))))
        #expect(gateway.lookups == ["id:known"])
    }

    // Catches absence being accepted with limited/revoked access, or an empty lookup saving a replacement.
    @Test func limitedAccessCannotProveAnUncertainSaveAbsent() async throws {
        for accesses: [LibraryAccess] in [[.limited], [.denied], [.restricted], [.notDetermined], [.full, .limited]] {
            let gateway = FakePhotoWriteGateway(); gateway.accesses = accesses
            #expect(try await PhotoLibraryWriter(gateway: gateway).findExport(operationID: UUID(), knownAssetID: nil, originalAssetID: nil) == .inaccessible)
            #expect(gateway.assets.isEmpty)
        }
        let gateway = FakePhotoWriteGateway()
        #expect(try await PhotoLibraryWriter(gateway: gateway).findExport(operationID: UUID(), knownAssetID: nil, originalAssetID: nil) == .notFound)
        #expect(gateway.assets.isEmpty)
    }

    // Catches arbitrary choice when a filename has been duplicated by an external import.
    @Test func duplicateIdentityAndLookupFailureNeverBecomeAbsence() async throws {
        let f = try WriterFixture(); defer { f.remove() }
        let gateway = FakePhotoWriteGateway()
        gateway.matches = ["one", "two"].map { .init(assetID: $0, filename: "FujiStudio-11111111-2222-3333-4444-555555555555.jpg", photosGeometry: .init(width: 7728, height: 5152)) }
        await #expect(throws: PhotoLibraryWriteError.ambiguousOperation(f.operationID)) {
            _ = try await PhotoLibraryWriter(gateway: gateway).findExport(operationID: f.operationID, knownAssetID: nil, originalAssetID: nil)
        }
        gateway.lookupError = .lookupFailed("synthetic offline")
        await #expect(throws: PhotoLibraryWriteError.lookupFailed("synthetic offline")) {
            _ = try await PhotoLibraryWriter(gateway: gateway).findExport(operationID: f.operationID, knownAssetID: nil, originalAssetID: nil)
        }
    }

    // Catches accepting a stale successful known-ID fetch after authorization was revoked.
    @Test func knownAssetFetchRechecksAuthorizationBeforeReturning() async throws {
        let f = try WriterFixture(); defer { f.remove() }
        let gateway = FakePhotoWriteGateway(); gateway.accesses = [.full, .denied]
        gateway.known = .init(assetID: "known", filename: "FujiStudio-11111111-2222-3333-4444-555555555555.jpg", photosGeometry: .init(width: 5152, height: 7728))
        #expect(try await PhotoLibraryWriter(gateway: gateway).findExport(operationID: f.operationID, knownAssetID: "known", originalAssetID: nil) == .inaccessible)
    }

    // Catches treating Photos' oriented/edited dimensions as authoritative encoded geometry.
    @Test func recoveredPhotosGeometryIsOnlyAnObservation() async throws {
        let f = try WriterFixture(); defer { f.remove() }
        #expect(f.jpeg.orientation == 8)
        #expect(f.jpeg.width == 7728 && f.jpeg.height == 5152)
        for observed in [PixelSize(width: 5152, height: 7728), PixelSize(width: 640, height: 480)] {
            let gateway = FakePhotoWriteGateway()
            gateway.known = .init(assetID: "known", filename: "FujiStudio-11111111-2222-3333-4444-555555555555.jpg", photosGeometry: observed)
            #expect(try await PhotoLibraryWriter(gateway: gateway).findExport(operationID: f.operationID, knownAssetID: "known", originalAssetID: nil) == .found(.init(assetID: "known", operationID: f.operationID, photosGeometry: observed)))
        }
    }

    // Catches collapsing authorization, malformed-resource and other transaction failures.
    @Test func transactionFailuresRetainTheirTypedReason() async throws {
        let f = try WriterFixture(); defer { f.remove() }
        let failures: [(NSError, PhotoSaveFailure)] = [
            (.init(domain: PHPhotosErrorDomain, code: 3311), .authorization),
            (.init(domain: PHPhotosErrorDomain, code: 3310), .authorization),
            (.init(domain: PHPhotosErrorDomain, code: 3303), .invalidResource),
            (.init(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError), .insufficientStorage),
            (.init(domain: "synthetic", code: 99), .transaction(domain: "synthetic", code: 99))
        ]
        for (error, reason) in failures {
            let gateway = FakePhotoWriteGateway(); gateway.outcome = (false, error)
            await #expect(throws: PhotoLibraryWriteError.rejected(reason)) {
                _ = try await PhotoLibraryWriter(gateway: gateway).saveJPEG(f.request()) { _ in }
            }
        }
        let gateway = FakePhotoWriteGateway(); gateway.outcome = (true, NSError(domain: "synthetic", code: 99))
        await #expect(throws: PhotoLibraryWriteError.uncertain(.transaction(domain: "synthetic", code: 99))) {
            _ = try await PhotoLibraryWriter(gateway: gateway).saveJPEG(f.request()) { _ in }
        }
    }

    // Catches a cancelled request starting a new irreversible transaction.
    @Test func cancellationBeforeSubmissionCreatesNothing() async throws {
        let f = try WriterFixture(); defer { f.remove() }
        let gateway = FakePhotoWriteGateway()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) {
                _ = try await PhotoLibraryWriter(gateway: gateway).saveJPEG(f.request()) { _ in }
            }
        }
        await task.value
        #expect(gateway.assets.isEmpty)
    }

    // Catches default fetches omitting ordinary hidden or burst assets during proof of absence.
    @Test func nativeRecoveryFetchIncludesHiddenAssetsWithoutLimit() {
        let options = NativePhotoWriteGateway.recoveryFetchOptions()
        #expect(options.includeHiddenAssets)
        #expect(options.includeAllBurstAssets)
        #expect(options.includeAssetSourceTypes == [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced])
        #expect(options.fetchLimit == 0)
        #expect(options.predicate == nil)
    }
}

private final class WriterEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

private final class FakeNewPhotoAsset: PhotoAssetCreating {
    struct Resource {
        let type: PHAssetResourceType, url: URL, filename: String?, contentType: UTType?, shouldMoveFile: Bool, sha256: String
    }
    var date: Date?, location: PhotoLocation?
    var dateAssignments = 0, locationAssignments = 0
    var resources: [Resource] = []
    let placeholderID: String?
    init(placeholderID: String?) { self.placeholderID = placeholderID }
    func setCreationDate(_ date: Date) { self.date = date; dateAssignments += 1 }
    func setLocation(_ location: PhotoLocation) { self.location = location; locationAssignments += 1 }
    func addResource(type: PHAssetResourceType, fileURL: URL, options: PHAssetResourceCreationOptions) {
        let data = (try? Data(contentsOf: fileURL)) ?? Data()
        resources.append(.init(type: type, url: fileURL, filename: options.originalFilename,
            contentType: options.contentType, shouldMoveFile: options.shouldMoveFile,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()))
    }
}

private final class FakePhotoWriteGateway: PhotoWriteGateway, PhotoAssetFactory, @unchecked Sendable {
    var accesses: [LibraryAccess] = [.full]
    var outcome: (Bool, NSError?) = (true, nil)
    var placeholder: String? = "synthetic-new"
    var assets: [FakeNewPhotoAsset] = []
    var known: PhotoSavedResource?, matches: [PhotoSavedResource] = []
    var lookupError: PhotoLibraryWriteError?
    var lookups: [String] = []
    var deferCompletion = false
    private let lock = NSLock()
    private var completion: (@Sendable (Bool, NSError?) -> Void)?
    private var waiter: CheckedContinuation<Void, Never>?
    func access() async -> LibraryAccess {
        if accesses.count > 1 { return accesses.removeFirst() }
        return accesses[0]
    }
    func makeAsset() -> any PhotoAssetCreating {
        let asset = FakeNewPhotoAsset(placeholderID: placeholder); assets.append(asset); return asset
    }
    func performChanges(_ changes: @escaping @Sendable (any PhotoAssetFactory) -> Void,
                        completion: @escaping @Sendable (Bool, NSError?) -> Void) {
        changes(self)
        if deferCompletion {
            lock.withLock { self.completion = completion; waiter?.resume(); waiter = nil }
        } else { completion(outcome.0, outcome.1) }
    }
    func waitForSubmission() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if completion != nil { continuation.resume() } else { waiter = continuation }
            }
        }
    }
    func complete(success: Bool, error: NSError?) {
        let callback = lock.withLock { let callback = completion; completion = nil; return callback }
        callback?(success, error)
    }
    func asset(id: String) async throws -> PhotoSavedResource? {
        lookups.append("id:\(id)"); if let lookupError { throw lookupError }; return known
    }
    func assets(filename: String) async throws -> [PhotoSavedResource] {
        lookups.append("filename:\(filename)"); if let lookupError { throw lookupError }; return matches
    }
}

private struct WriterFixture: Sendable {
    let operationID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    let date = Date(timeIntervalSince1970: 100)
    let location = PhotoLocation(latitude: 1, longitude: 2, altitude: 3)
    let bytes = Data([0xFF, 0xD8, 0xFF, 0xFE, 0, 6, 84, 69, 83, 84, 0xFF, 0xD9])
    let directory: URL
    let jpeg: CameraJPEG
    var hash: String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("camera.JPG")
        try bytes.write(to: url)
        let profile = try ProductionProfileFixture()
        let camera = CameraExecutionContext(model: "X-T5", firmware: "synthetic", capability: "synthetic", supportVersion: "synthetic", sessionIdentity: UUID(), generation: 1)
        let key = RenderKey(sourceID: "synthetic-source", sourceRevision: "revision", sourceSHA256: "synthetic-raw", settingsDigest: "synthetic-settings", cameraContext: camera, width: 7728, height: 5152, orientation: 8, policy: .fullSizeFineRecordedGeometry, quality: .fullResolutionFine)
        jpeg = CameraJPEG(fileURL: url, sourceID: key.sourceID, sourceRevision: key.sourceRevision, sourceSHA256: key.sourceSHA256, recipeSnapshotID: profile.bank.id, settingsDigest: key.settingsDigest, cameraContext: camera, operationID: UUID(), width: key.width, height: key.height, orientation: key.orientation, quality: key.quality,
            effectiveRecipe: .init(supportVersion: "synthetic", requested: try profile.bank.settings(using: RecipeCodecRegistry()), dormantGrainSizeNotSerialized: false, inactiveKelvinPreserved: false, lensOptimizerRequested: true, lensOptimizerEffective: false, lensOptimizerAdjusted: true, evidence: "synthetic"), baselineSHA256: "synthetic-baseline", candidateSHA256: "synthetic-candidate", outputSHA256: "synthetic-output", key: key)
    }
    func request(metadata: Bool = true) -> PhotoSaveRequest {
        .init(jpeg: jpeg, operationID: operationID, captureDate: metadata ? date : nil, location: metadata ? location : nil)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
