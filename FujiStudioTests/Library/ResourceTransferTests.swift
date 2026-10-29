@testable import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

struct ResourceTransferTests {
    @Test func recognizesPOSIXStorageExhaustion() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: 28)
        #expect(ResourceFileTransfer.fileError(error) == .insufficientStorage)
    }

    @Test func streamsChunksAndReturnsChecksum() async throws {
        let transfer = try ResourceFileTransfer(token: token)
        let result = try await transfer.run { data, done in
            data(Data("abc".utf8))
            done(nil)
            return { }
        }
        defer { try? FileManager.default.removeItem(at: result.fileURL) }
        #expect(try Data(contentsOf: result.fileURL) == Data("abc".utf8))
        #expect(result.checksum == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func cancellationBeforeRequestRegistrationCleansPartialFile() async throws {
        let transfer = try ResourceFileTransfer(token: token)
        transfer.cancel()
        await #expect(throws: CancellationError.self) {
            try await transfer.run { _, _ in Issue.record("Cancelled transfer must not start"); return {} }
        }
        #expect(!FileManager.default.fileExists(atPath: transfer.fileURL.path))
    }

    @Test func cancellationDuringRegistrationCancelsRequestAndIgnoresLateData() async throws {
        let transfer = try ResourceFileTransfer(token: token)
        let cancellation = CancellationReceipt()
        await #expect(throws: CancellationError.self) {
            try await transfer.run { data, done in
                data(Data("partial".utf8))
                transfer.cancel()
                data(Data("late".utf8))
                done(nil)
                return { cancellation.mark() }
            }
        }
        #expect(cancellation.wasCalled)
        #expect(!FileManager.default.fileExists(atPath: transfer.fileURL.path))
    }

    @Test func networkFailureRemovesPartialResource() async throws {
        let transfer = try ResourceFileTransfer(token: token)
        await #expect(throws: ResourceError.retrievalFailed("offline")) {
            try await transfer.run { data, done in
                data(Data("partial".utf8))
                done(ResourceError.retrievalFailed("offline"))
                return {}
            }
        }
        #expect(!FileManager.default.fileExists(atPath: transfer.fileURL.path))
    }

    @Test func taskCancellationPropagatesToPhotoKitRequest() async throws {
        let transfer = try ResourceFileTransfer(token: token)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let cancellation = CancellationReceipt()
        let task = Task {
            try await transfer.run { _, _ in
                signal.yield(())
                signal.finish()
                return { cancellation.mark() }
            }
        }
        for await _ in started { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(cancellation.wasCalled)
        #expect(!FileManager.default.fileExists(atPath: transfer.fileURL.path))
    }

    private var token: ResourceToken {
        ResourceToken(assetID: "source", role: .alternateOriginal, contentTypeIdentifier: "com.fuji.raw-image",
                      format: .raf, originalFilename: "test.RAF", discriminator: "fixture")
    }
}

private final class CancellationReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    func mark() { lock.withLock { called = true } }
    var wasCalled: Bool { lock.withLock { called } }
}
