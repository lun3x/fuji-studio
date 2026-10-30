import FujiCameraCore
import Foundation

/// A bounded metadata prefix, with no temporary file or whole-resource checksum.
/// Success cancels the remaining stream; callbacks and request registration may race.
final class ResourceMetadataTransfer: @unchecked Sendable {
    typealias Start = ResourceFileTransfer.Start
    private let byteCount: Int?
    private let lock = NSLock()
    private let maximumPrefixSize = 32 * 1024 * 1024
    private var prefix = Data()
    private var receivedByteCount = 0
    private var hasMetadata = false
    private var continuation: CheckedContinuation<RAWMetadata, Error>?
    private var terminal: Result<RAWMetadata, Error>?
    private var cancelRequest: (@Sendable () -> Void)?
    private var abortRequest = false

    init(token: ResourceToken) { byteCount = token.byteCount.flatMap(Int.init(exactly:)) }

    func run(start: Start, isolation: isolated (any Actor)? = #isolation) async throws -> RAWMetadata {
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
            receivedByteCount += data.count
            // For unknown sizes, keep only the parsed metadata prefix until EOF validates bounds.
            guard !hasMetadata else { return nil }
            prefix.append(data.prefix(maximumPrefixSize - prefix.count))
            do {
                if let metadata = try RAFMetadataReader().metadata(in: prefix, fileByteCount: byteCount) {
                    hasMetadata = true
                    if byteCount != nil {
                        abortRequest = true
                        let request = cancelRequest
                        completeLocked(.success(metadata))
                        return request
                    }
                } else if prefix.count == maximumPrefixSize {
                    throw ResourceError.invalidRAF("RAF metadata exceeds the inspection limit")
                }
                return nil
            } catch {
                abortRequest = true
                let request = cancelRequest
                completeLocked(.failure(error))
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
                guard let metadata = try RAFMetadataReader().metadata(in: prefix, fileByteCount: receivedByteCount) else {
                    throw ResourceError.invalidRAF("Truncated RAF metadata")
                }
                completeLocked(.success(metadata))
            } catch { completeLocked(.failure(error)) }
        }
    }

    private func completeLocked(_ result: Result<RAWMetadata, Error>) {
        terminal = result
        prefix = Data()
        cancelRequest = nil
        continuation?.resume(with: result)
        continuation = nil
    }
}
