import Foundation
import Testing
@testable import FujiCameraCore
@testable import FujiStudio

@MainActor struct PairVersionListTests {
    @Test func pairedExportIsTheOriginalJPEGAndDoesNotAddADuplicateSavedVersion() throws {
        let f = try RenderFixture(); defer { f.remove() }
        let source = pairReplacementSource(f.source), jpeg = try f.jpeg()
        let pair = SavedVersion(id: UUID(), sourceID: source.id, outputAssetID: source.id, recipeSnapshot: f.recipe,
            operationID: UUID(), exportedAt: Date(timeIntervalSince1970: 10), jpeg: jpeg, availability: .available, destination: .createPair)
        let entries = VersionList(source: source, saved: [pair]).entries
        #expect(entries.map(\.id) == [.raw, .cameraJPEG])
        #expect(entries.last?.label == "Paired JPEG")
        let edit = SavedVersion(id: UUID(), sourceID: source.id, outputAssetID: source.id, recipeSnapshot: f.recipe,
            operationID: UUID(), exportedAt: Date(timeIntervalSince1970: 20), jpeg: jpeg, availability: .available, destination: .updateOriginal)
        #expect(VersionList(source: source, saved: [pair, edit]).entries.map(\.id) == [.raw, .cameraJPEG, .saved(edit.id)])
    }
}
