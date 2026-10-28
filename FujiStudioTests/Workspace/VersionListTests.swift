@testable import FujiCameraCore
import Foundation
import CoreGraphics
import Testing
@testable import FujiStudio

@MainActor
struct VersionListTests {
    @Test func savedPhoneVersionShowsPhoneIdentityInsteadOfItsOriginalCameraSlot() throws {
        let f = try RenderFixture(); defer { f.remove() }
        let recipe = f.recipe(named: "Phone preset").copiedToPhone()
        let version = saved(f, jpeg: try f.jpeg(), recipe: recipe.snapshot)
        let entry = try #require(VersionList(source: f.source, saved: [version]).entries.last)
        #expect(entry.recipeSlot == nil)
        #expect(entry.isPhoneRecipe)
        #expect(entry.accessibilityLabel.contains("Phone recipe Phone preset"))
    }

    @Test func onlyOriginalsAndExplicitSavedSourceAssociationsAppear() throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try f.jpeg(), a = saved(f, jpeg: jpeg), foreign = saved(f, jpeg: jpeg, sourceID: "other")
        let list = VersionList(source: f.source, saved: [a, foreign])
        #expect(list.entries.map(\.id) == [.raw, .saved(a.id)])
        #expect(list.entries.map(\.accessibilityIdentifier) == ["version.raw", "version.saved.\(a.id.uuidString)"])
        let paired = PhotoSource(id: f.source.id, originalResources: .init(raf: f.token, jpeg: .init(assetID: f.source.id,
            role: .alternateOriginal, contentTypeIdentifier: "public.jpeg", format: .jpeg, originalFilename: "original.JPG", discriminator: "jpeg")),
            captureDate: nil, location: nil, resourceRevision: f.source.resourceRevision)
        #expect(VersionList(source: paired, saved: []).entries.map(\.id) == [.raw, .cameraJPEG])
    }
    @Test func sameMinuteExportsHaveCompactDatesDistinctLabelsAndUnavailableRecordsRemain() throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try f.jpeg(), recipe = f.recipe(named: "Job chosen name")
        let date = Date(timeIntervalSince1970: 1_793_108_340) // 27 October 2026, 13:39 UTC.
        let a = saved(f, jpeg: jpeg, recipe: recipe, exportedAt: date)
        let b = saved(f, jpeg: jpeg, recipe: recipe, exportedAt: date.addingTimeInterval(30))
        let deleted = saved(f, jpeg: jpeg, recipe: recipe, availability: .deleted, exportedAt: date.addingTimeInterval(45))
        let entries = VersionList(source: f.source, saved: [b, a, deleted],
            timeZone: TimeZone(secondsFromGMT: 0)!).entries.filter { if case .saved = $0.id { true } else { false } }
        #expect(entries.count == 3)
        #expect(Set(entries.map(\.accessibilityLabel)).count == 3)
        #expect(entries.first { $0.id == .saved(a.id) }?.subtitle == "27/10/26 13:39 · Export 1")
        #expect(entries.first { $0.id == .saved(b.id) }?.subtitle == "27/10/26 13:39 · Export 2")
        #expect(entries.allSatisfy { $0.label == "Job chosen name" && $0.recipeSlot == 7 })
        #expect(entries.contains { $0.subtitle?.contains("unavailable") == true })
        let local = VersionList(source: f.source, saved: [a],
            timeZone: TimeZone(secondsFromGMT: 3600)!).entries.first { $0.id == .saved(a.id) }
        #expect(local?.subtitle == "27/10/26 14:39")
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
                       recipe: RecipeSnapshot? = nil, availability: AssetAvailability = .available,
                       exportedAt: Date = Date(timeIntervalSince1970: 100)) -> SavedVersion {
        SavedVersion(id: UUID(), sourceID: sourceID ?? f.source.id, outputAssetID: UUID().uuidString,
            recipeSnapshot: recipe ?? f.recipe, operationID: UUID(), exportedAt: exportedAt, jpeg: jpeg, availability: availability)
    }
}
