@testable import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

struct ResourceMetadataTransferTests {
    @Test func completesFromMetadataAndCancelsUndeliveredLargePayload() async throws {
        let (token, bytes) = try fixture(largePayload: true)
        let transfer = ResourceMetadataTransfer(token: token), cancellation = MetadataCancellation()
        let metadata = try await transfer.run { data, done in
            for chunk in stride(from: 0, to: bytes.count, by: 41) {
                data(Data(bytes[chunk..<min(bytes.count, chunk + 41)]))
            }
            // No completion or sensor pixel payload is needed. Registration can race success.
            done(ResourceError.retrievalFailed("late completion"))
            return { cancellation.mark() }
        }
        #expect(metadata.cameraModel == "X-T5")
        #expect(metadata.recordedGeometry == PixelSize(width: 7728, height: 5152))
        #expect(cancellation.wasCalled)
    }

    @Test func unknownSizeUsesCompletionToRejectTruncatedPayload() async throws {
        var (token, bytes) = try fixture(largePayload: true)
        token.byteCount = nil
        let transfer = ResourceMetadataTransfer(token: token)
        await #expect(throws: ResourceError.self) {
            try await transfer.run { data, done in data(bytes); done(nil); return {} }
        }
    }

    @Test func unknownSizeAcceptsCompleteResource() async throws {
        var (token, bytes) = try fixture()
        token.byteCount = nil
        let metadata = try await ResourceMetadataTransfer(token: token).run { data, done in
            data(bytes); done(nil); return {}
        }
        #expect(metadata.orientation == 6)
    }

    @Test func cancellationDuringRegistrationIgnoresLateData() async throws {
        let (token, bytes) = try fixture()
        let transfer = ResourceMetadataTransfer(token: token), cancellation = MetadataCancellation()
        await #expect(throws: CancellationError.self) {
            try await transfer.run { data, done in
                data(Data(bytes.prefix(30))); transfer.cancel(); data(bytes); done(nil)
                return { cancellation.mark() }
            }
        }
        #expect(cancellation.wasCalled)
    }

    @Test func cancelledTransferNeverStartsRequest() async throws {
        let (token, _) = try fixture(), transfer = ResourceMetadataTransfer(token: token)
        transfer.cancel()
        await #expect(throws: CancellationError.self) {
            try await transfer.run { _, _ in Issue.record("Cancelled request started"); return {} }
        }
    }

    @Test func transientFailureIsReturned() async throws {
        let (token, _) = try fixture()
        await #expect(throws: ResourceError.retrievalFailed("offline")) {
            try await ResourceMetadataTransfer(token: token).run { data, done in
                data(Data(repeating: 0, count: 10)); done(ResourceError.retrievalFailed("offline")); return {}
            }
        }
    }

    @Test func taskCancellationPropagatesToRegisteredRequest() async throws {
        let (token, _) = try fixture(), transfer = ResourceMetadataTransfer(token: token)
        let (started, signal) = AsyncStream<Void>.makeStream(), cancellation = MetadataCancellation()
        let task = Task {
            try await transfer.run { _, _ in
                signal.yield(()); signal.finish()
                return { cancellation.mark() }
            }
        }
        for await _ in started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cancellation.wasCalled)
    }

    @Test func excessiveMetadataPrefixFailsWithinMemoryLimit() async throws {
        var (token, bytes) = try fixture(largePayload: true)
        // Move the JPEG beyond the bounded prefix, without allocating the declared RAW size.
        bytes.replaceSubrange(84..<88, with: withUnsafeBytes(of: UInt32(40 * 1024 * 1024).bigEndian) { Data($0) })
        token.byteCount = 100 * 1024 * 1024
        let header = Data(bytes.prefix(128)), transfer = ResourceMetadataTransfer(token: token)
        let cancellation = MetadataCancellation()
        await #expect(throws: ResourceError.invalidRAF("RAF metadata exceeds the inspection limit")) {
            try await transfer.run { data, _ in
                data(header)
                let chunk = Data(repeating: 0, count: 1024 * 1024)
                for _ in 0..<32 { data(chunk) }
                return { cancellation.mark() }
            }
        }
        #expect(cancellation.wasCalled)
    }

    private func fixture(largePayload: Bool = false) throws -> (ResourceToken, Data) {
        let local = try rafMetadataFixture(model: "X-T5")
        defer { try? FileManager.default.removeItem(at: local.fileURL) }
        var bytes = try Data(contentsOf: local.fileURL), token = local.token
        token.byteCount = Int64(bytes.count)
        if largePayload {
            let offset = bytes[100..<104].reduce(0) { ($0 << 8) | Int($1) }, length = 80 * 1024 * 1024
            bytes.replaceSubrange(104..<108, with: withUnsafeBytes(of: UInt32(length).bigEndian) { Data($0) })
            token.byteCount = Int64(offset + length)
        }
        return (token, bytes)
    }
}

private final class MetadataCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    func mark() { lock.withLock { called = true } }
    var wasCalled: Bool { lock.withLock { called } }
}
