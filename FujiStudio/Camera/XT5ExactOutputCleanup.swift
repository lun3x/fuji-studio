import FujiCameraCore
import Foundation
import CryptoKit

/// Explicit engineering ownership proof: a controller-authorized preserved result, or an
/// output created/captured by the bounded batch. Never generic new/first-handle inference.
struct XT5ExactCleanupTarget: Sendable {
    let handle: UInt32
    let sourceSHA256: String
    let outputSHA256: String
    let quarantineURL: URL
    let objectInfo: Data
    let storageInfo: Data
    var attemptURL: URL { quarantineURL.deletingLastPathComponent().appendingPathComponent("exact-cleanup-attempt.json") }
    func validateLocal(raw: PreparedRAW) throws -> XT5ObjectInfo {
        guard handle != 0 && handle != UInt32.max,
              sourceSHA256 == raw.sha256,
              try ResourceChecksum.sha256(raw.fileURL) == sourceSHA256,
              try ResourceChecksum.sha256(quarantineURL) == outputSHA256,
              !FileManager.default.fileExists(atPath: attemptURL.path) else { throw XT5ExactCleanupIssue.invalidPreservedProof }
        let info = try XT5ConversionCodec.objectInfo(objectInfo)
        let storage = try XT5ConversionCodec.storageInfo(storageInfo)
        guard info.format == 0x3801, info.protection == 0, info.byteCount > 0, info.byteCount <= PTPCodec.maximumDataBytes,
              try quarantineURL.resourceValues(forKeys: [.fileSizeKey]).fileSize == Int(info.byteCount),
              storage.storageType == 3, storage.filesystemType == 2, storage.access == 2 else { throw XT5ExactCleanupIssue.invalidPreservedProof }
        return info
    }
}
enum XT5ExactCleanupIssue: Error, Sendable { case invalidPreservedProof, objectChanged, payloadChanged, viewNotEmpty, attemptAlreadyRecorded }
struct XT5ExactCleanupObservation: Sendable, Encodable {
    var identityVerified = false
    var deleteIntentRecorded = false
    var deleteAttempted = false
    var deleteAcknowledged = false
    var emptyViewVerified = false
    var failure: String?
}

actor XT5ExactOutputCleanup {
    typealias Send = @Sendable (UInt16, [UInt32], Data?) async throws -> PTPReply
    private let send: Send
    init(send: @escaping Send) { self.send = send }
    func run(target: XT5ExactCleanupTarget, raw: PreparedRAW, directory: URL,
             onUpdate: @Sendable (XT5ExactCleanupObservation) async -> Void) async -> XT5ExactCleanupObservation {
        var report = XT5ExactCleanupObservation()
        do {
            let info = try target.validateLocal(raw: raw)
            try await revalidate(target: target, info: info)
            // The only full candidate payload ends before any source RAW upload can begin.
            do {
                let data = try await send(0x1009, [target.handle], nil).data
                guard data.count == info.byteCount,
                      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == target.outputSHA256 else { throw XT5ExactCleanupIssue.payloadChanged }
            }
            report.identityVerified = true
            await onUpdate(report)
            let proof = ["sourceSHA256": target.sourceSHA256, "outputSHA256": target.outputSHA256,
                         "handle": String(target.handle), "intent": "one exact DeleteObject attempt; never replay automatically"]
            let proofData = try JSONEncoder().encode(proof)
            // Exclusive creation is a conservative durable one-shot guard. A partial marker also
            // blocks replay; no automatic removal/reset even if a later check aborts before delete.
            do { try proofData.write(to: target.attemptURL, options: [.withoutOverwriting, .completeFileProtection]) }
            catch { throw XT5ExactCleanupIssue.attemptAlreadyRecorded }
            report.deleteIntentRecorded = true
            try proofData.write(to: directory.appendingPathComponent("exact-cleanup-proof.json"), options: [.atomic,.completeFileProtection])
            await onUpdate(report)
            // No await to a UI/file writer between this final view and the one exact deletion.
            try await revalidate(target: target, info: info)
            report.deleteAttempted = true
            _ = try await send(0x100B, [target.handle,0], nil)
            report.deleteAcknowledged = true
            let remaining = try XT5ConversionCodec.objectHandles(await send(0x1007, [UInt32.max,0,0], nil).data)
            guard remaining.isEmpty else { throw XT5ExactCleanupIssue.viewNotEmpty }
            report.emptyViewVerified = true
        } catch { report.failure = XT5RawBaselineProbe.safeFailure(error) }
        await onUpdate(report)
        return report
    }
    private func revalidate(target: XT5ExactCleanupTarget, info: XT5ObjectInfo) async throws {
        guard try XT5ConversionCodec.objectHandles(await send(0x1007, [UInt32.max,0,0], nil).data) == [target.handle],
              try await send(0x1008, [target.handle], nil).data == target.objectInfo,
              try await send(0x1005, [info.storageID], nil).data == target.storageInfo,
              try XT5ConversionCodec.objectHandles(await send(0x1007, [UInt32.max,0,0], nil).data) == [target.handle] else { throw XT5ExactCleanupIssue.objectChanged }
    }
}
