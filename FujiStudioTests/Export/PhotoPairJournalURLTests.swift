import Foundation
import Testing
@testable import FujiCameraCore
@testable import FujiStudio

struct PhotoPairJournalURLTests {
    @Test func followsApplicationSupportDirectorySymlinksWithoutRejectingTheIntent() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let support = f.root.appendingPathComponent("canonical-support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let alias = f.root.appendingPathComponent("support-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: support)
        let journal = PhotoPairJournal(directory: alias.appendingPathComponent("pairs", isDirectory: true))
        let intent = intent(f)
        try await journal.store(intent)
        #expect(try await journal.all() == [intent])
    }
    @Test func refusesAnIntentWhoseOperationDoesNotMatchItsFilename() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let directory = f.root.appendingPathComponent("pairs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(intent(f)).write(to: directory.appendingPathComponent(UUID().uuidString + ".json"))
        await #expect(throws: ResourceError.resourceChanged) { try await PhotoPairJournal(directory: directory).all() }
    }
    private func intent(_ f: RenderFixture) -> PhotoPairIntent {
        .init(operationID: UUID(), source: f.source, originalState: .init(assetID: f.source.id,
            modificationDate: nil, captureDate: nil, location: nil, isFavorite: false, isHidden: false,
            caption: nil, rating: 0, keywords: [], albumIDs: []), rawSHA256: f.raw.sha256,
            jpegSHA256: "diagnostic", width: 1, height: 1, orientation: 1)
    }
}
