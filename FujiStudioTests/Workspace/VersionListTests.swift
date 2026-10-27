import Foundation
import CoreGraphics
import Testing
@testable import FujiStudio

@MainActor
struct VersionListTests {
    @Test func onlyExplicitSourceAssociationsAndRealPreviewAppear() throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try f.jpeg(), a = saved(f, jpeg: jpeg), foreign = saved(f, jpeg: jpeg, sourceID: "other")
        let list = VersionList(source: f.source, saved: [a, foreign], preview: jpeg)
        #expect(list.entries.map(\.id) == [.raw, .saved(a.id), .preview(jpeg.key)])
        #expect(list.entries.map(\.accessibilityIdentifier) == ["version.raw", "version.saved.\(a.id.uuidString)", "version.preview"])
        let paired = PhotoSource(id: f.source.id, originalResources: .init(raf: f.token, jpeg: .init(assetID: f.source.id,
            role: .alternateOriginal, contentTypeIdentifier: "public.jpeg", format: .jpeg, originalFilename: "original.JPG", discriminator: "jpeg")),
            captureDate: nil, location: nil, resourceRevision: f.source.resourceRevision)
        #expect(VersionList(source: paired, saved: [], preview: nil).entries.map(\.id) == [.raw, .cameraJPEG])
        #expect(VersionList(source: f.source, saved: [], preview: try f.jpeg(key: f.key(revision: "old"))).entries.map(\.id) == [.raw])
    }
    @Test func sameSecondExportsHaveDistinctJobRecipeLabelsAndUnavailableRecordsRemain() throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try f.jpeg(), recipe = f.recipe(named: "Job chosen name")
        let a = saved(f, jpeg: jpeg, recipe: recipe), b = saved(f, jpeg: jpeg, recipe: recipe)
        let deleted = saved(f, jpeg: jpeg, recipe: recipe, availability: .deleted)
        let entries = VersionList(source: f.source, saved: [b, a, deleted], preview: nil).entries.filter { if case .saved = $0.id { true } else { false } }
        #expect(entries.count == 3)
        #expect(Set(entries.map(\.label)).count == 3)
        #expect(entries.first { $0.id == .saved(a.id) }?.label != entries.first { $0.id == .saved(b.id) }?.label)
        #expect(entries.allSatisfy { $0.label.contains("Job chosen name") && $0.label.contains("Exported") })
        #expect(entries.contains { $0.label.contains("unavailable") })
        #expect(jpeg.recipeSnapshotID != recipe.id)
    }
    @Test func recordedGeometryAndOrientationAreSeparateFromFitFileResolution() {
        let geometry = ImageGeometry(encoded: PixelSize(width: 7728, height: 5152), orientation: 6)
        #expect(geometry.upright == PixelSize(width: 5152, height: 7728))
        #expect(geometry.matchesInspection(ImageGeometry(encoded: PixelSize(width: 5152, height: 7728), orientation: 1)))
        #expect(!geometry.matchesInspection(ImageGeometry(encoded: PixelSize(width: 2048, height: 1365), orientation: 1)))
        let region = CGRect(x: 0.2, y: 0.1, width: 0.3, height: 0.25)
        let ci = ImageGeometry.bottomLeftRegion(region)
        #expect(abs(ci.minY - 0.65) < 0.00001)
        #expect(ci.minX == region.minX && ci.size == region.size)
    }
    @Test func rawContainerAndRecordedCropRemainDistinctFromUprightInspection() {
        let raw = ImageGeometry(encoded: PixelSize(width: 7872, height: 5196), orientation: 8,
            recorded: PixelSize(width: 7728, height: 5152))
        #expect(raw.encoded == PixelSize(width: 7872, height: 5196))
        #expect(raw.recorded == PixelSize(width: 7728, height: 5152))
        #expect(raw.upright == PixelSize(width: 5152, height: 7728))
        #expect(raw.matchesInspection(ImageGeometry(encoded: PixelSize(width: 7728, height: 5152), orientation: 8)))
    }
    @Test func displayCopySurvivesPinMoveUnpinAndEvictionUntilLeaseEnds() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let cache = try f.cache(), jpeg = try f.jpeg()
        try await cache.store(jpeg, key: jpeg.key)
        var lease: DisplayFileLease? = try await cache.copyForDisplay(jpeg.key)
        let url = try #require(lease?.fileURL)
        #expect(try ResourceChecksum.sha256(url) == jpeg.outputSHA256)
        _ = try await cache.pin(jpeg.key)
        await cache.unpin(jpeg.key)
        await cache.invalidate(sourceID: jpeg.sourceID)
        #expect(FileManager.default.fileExists(atPath: url.path))
        lease = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    private func saved(_ f: RenderFixture, jpeg: CameraJPEG, sourceID: String? = nil,
                       recipe: RecipeSnapshot? = nil, availability: AssetAvailability = .available) -> SavedVersion {
        SavedVersion(id: UUID(), sourceID: sourceID ?? f.source.id, outputAssetID: UUID().uuidString,
            recipeSnapshot: recipe ?? f.recipe, operationID: UUID(), exportedAt: Date(timeIntervalSince1970: 100), jpeg: jpeg, availability: availability)
    }
}
