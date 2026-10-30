@testable import FujiCameraCore
import Foundation
@testable import FujiStudio

/// Only the PhotoKit boundary is replaced; real pool/parser/resolver/coordinators remain composed.
actor CorrectionLibrary: PhotoLibraryReading {
    let base: FixtureLibrary
    private var rawBytes: [SourceID: Data] = [:]
    private(set) var rawMaterializations = 0
    private var held: Set<String> = []
    private var receipts: [String: TransferReceipt] = [:]
    private(set) var admittedBeforeCleanup = false
    func holdNext(_ id: String, format: ResourceFormat) { held.insert(id + format.rawValue) }
    func receipt(_ id: String, format: ResourceFormat) -> TransferReceipt? { receipts[id + format.rawValue] }
    func cancelAll() { receipts.values.forEach { $0.transfer.cancel() } }

    init(base: FixtureLibrary) { self.base = base }
    func setRAW(_ id: SourceID, bytes: Data) { rawBytes[id] = bytes }
    func requestAccess() async -> LibraryAccess { await base.requestAccess() }
    func sources() async -> AsyncThrowingStream<[PhotoSource], Error> { await base.sources() }
    func source(id: SourceID) async throws -> PhotoSource { try await base.source(id: id) }
    func resources(assetID: String) async throws -> [ResourceToken] { try await base.resources(assetID: assetID) }
    func changes() async -> AsyncStream<LibraryChange> { await base.changes() }
    func rawMetadata(_ resource: ResourceToken) async throws -> RAWMetadata {
        guard let bytes = rawBytes[resource.assetID] else { return try await base.rawMetadata(resource) }
        guard let metadata = try RAFMetadataReader().metadata(in: bytes, fileByteCount: bytes.count) else {
            throw ResourceError.invalidRAF("Truncated fixture")
        }
        return metadata
    }
    func materialize(_ resource: ResourceToken, progress: @escaping @Sendable (Double) -> Void) async throws -> LocalResource {
        let key = resource.assetID + resource.format.rawValue
        if resource.format == .raf, receipts.values.contains(where: { $0.cancelled && !$0.cleanupComplete }) { admittedBeforeCleanup = true }
        if held.remove(key) != nil {
            if resource.format == .raf { rawMaterializations += 1 }
            let transfer = try ResourceFileTransfer(token: resource), receipt = TransferReceipt(transfer: transfer, progress: progress)
            receipts[key] = receipt
            do {
                return try await transfer.run { data, _ in
                    data(Data("partial synthetic resource".utf8)); receipt.start(); progress(0.25)
                    return { receipt.cancelRequest() }
                }
            } catch {
                // Model an asynchronous cleanup/classification tail. The next RAW may enter only
                // after this boundary returns, even though cancellation already removed its file.
                await Task { try? await Task.sleep(for: .milliseconds(40)) }.value
                receipt.cleaned()
                throw error
            }
        }
        if resource.format == .raf {
            rawMaterializations += 1
            if let bytes = rawBytes[resource.assetID] {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-\(UUID()).RAF")
                try bytes.write(to: url)
                return LocalResource(token: resource, fileURL: url, checksum: try ResourceChecksum.sha256(url))
            }
        }
        return try await base.materialize(resource, progress: progress)
    }
}

/// The real transfer owns partial-file cleanup; this receipt represents the native request handle.
final class TransferReceipt: @unchecked Sendable {
    let transfer: ResourceFileTransfer
    private let lock = NSLock()
    private var didStart = false, didCancel = false, didClean = false
    private let progress: @Sendable (Double) -> Void
    init(transfer: ResourceFileTransfer, progress: @escaping @Sendable (Double) -> Void) { self.transfer = transfer; self.progress = progress }
    func start() { lock.withLock { didStart = true } }
    func cancelRequest() { lock.withLock { didCancel = true } }
    func cleaned() { lock.withLock { didClean = true } }
    var started: Bool { lock.withLock { didStart } }
    var cancelled: Bool { lock.withLock { didCancel } }
    var cleanupComplete: Bool { lock.withLock { didClean } }
    func lateProgress() { progress(0.9) }
}
