@testable import FujiCameraCore
import Foundation
import UIKit
import Testing
@testable import FujiStudio

@MainActor
struct VersionImageResolverTests {
    @Test func savedReadsOnlyAssociatedOriginalJPEGAndPropagatesCloudProgress() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let image = try jpegFixture(f)
        let token = ResourceToken(assetID: "saved-asset", role: .primaryOriginal, contentTypeIdentifier: "public.jpeg", format: .jpeg, originalFilename: "saved.JPG", discriminator: "original")
        let adjusted = ResourceToken(assetID: token.assetID, role: .adjusted, contentTypeIdentifier: "public.jpeg", format: .jpeg, originalFilename: "edit.JPG", discriminator: "adjusted")
        let version = saved(f, jpeg: image)
        let library = ViewerLibrary(original: image.fileURL, tokens: [adjusted, token])
        let catalog = ViewerCatalog([version]), progress = ViewerProgress()
        let resolver = try resolver(f, library: library, catalog: catalog)
        let file = try await resolver.resolve(source: f.source, version: .saved(version.id)) { value in progress.add(value) }
        #expect(file.geometry == ImageGeometry(encoded: PixelSize(width: 400, height: 300), orientation: 1))
        #expect(try ResourceChecksum.sha256(file.lease.fileURL) == image.outputSHA256)
        #expect(await library.requestedAssets == ["saved-asset"])
        #expect(await library.materialized == [token])
        #expect(progress.values == [0.25, 1])
        #expect(await library.transferred.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(await catalog.sourceIDs == [f.source.id])
    }
    @Test func deletedAndForeignVersionsDoNotRetrievePixelsAndAuthorizationIsTyped() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try jpegFixture(f), deleted = saved(f, jpeg: jpeg, availability: .deleted)
        let foreign = saved(f, jpeg: jpeg, sourceID: "foreign")
        let library = ViewerLibrary(original: jpeg.fileURL, tokens: [])
        let resolver = try resolver(f, library: library, catalog: ViewerCatalog([deleted, foreign]))
        await #expect(throws: ViewerError.unavailable(.deleted)) { try await resolver.resolve(source: f.source, version: .saved(deleted.id)) }
        await #expect(throws: ViewerError.invalidVersion) { try await resolver.resolve(source: f.source, version: .saved(foreign.id)) }
        #expect(await library.requestedAssets.isEmpty)
        let available = saved(f, jpeg: jpeg)
        let denied = try self.resolver(f, library: library, catalog: ViewerCatalog([available]))
        await library.setFailure(.authorization(.denied))
        await #expect(throws: ResourceError.authorization(.denied)) { try await denied.resolve(source: f.source, version: .saved(available.id)) }
    }
    @Test func savedEncodedGeometryMismatchAndAmbiguousOriginalsAreRejected() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try jpegFixture(f), wrong = saved(f, jpeg: try f.jpeg())
        let token = ResourceToken(assetID: "saved-asset", role: .primaryOriginal, contentTypeIdentifier: "public.jpeg", format: .jpeg, originalFilename: "saved.JPG", discriminator: "original")
        let library = ViewerLibrary(original: jpeg.fileURL, tokens: [token])
        let resolver = try resolver(f, library: library, catalog: ViewerCatalog([wrong]))
        await #expect(throws: ViewerError.invalidImage) { try await resolver.resolve(source: f.source, version: .saved(wrong.id)) }
        #expect(await library.transferred.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        await library.setTokens([token, token])
        await #expect(throws: ResourceError.ambiguousOriginalJPEG) { try await resolver.resolve(source: f.source, version: .saved(wrong.id)) }
    }
    @Test func rawDisplayLeaseCarriesRecordedGeometryNotTransformedFitFilePixels() throws {
        let f = try RenderFixture(); defer { f.remove() }
        let fit = try jpegFixture(f)
        let logical = ImageGeometry.raw(f.raw.metadata)
        let lease = try DisplayFileLease.copy(from: fit.fileURL, geometry: logical)
        #expect(lease.geometry?.encoded == f.raw.metadata.containerGeometry)
        #expect(lease.geometry?.recorded == f.raw.metadata.recordedGeometry)
        #expect(lease.geometry?.recordedOrigin == CGPoint(x: f.raw.metadata.cropLeft, y: f.raw.metadata.cropTop))
        #expect(lease.geometry?.orientation == f.raw.metadata.orientation)
        #expect(try ImageGeometry.read(lease.fileURL).encoded == PixelSize(width: 400, height: 300))
        #expect(lease.geometry?.upright != PixelSize(width: 400, height: 300))
        #expect(try DisplayFileLease.copy(from: fit.fileURL).geometry == nil)
    }
    @Test func jpegDetailUsesUprightTopLeftRegionAndKeepsInputLeaseAlive() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try jpegFixture(f), lease = try DisplayFileLease.copy(from: jpeg.fileURL)
        let renderer = JPEGDetailRenderer()
        let top = try await renderer.detail(file: lease, topLeftRegion: CGRect(x: 0, y: 0, width: 1, height: 0.5), maximumDimension: 400)
        let bottom = try await renderer.detail(file: lease, topLeftRegion: CGRect(x: 0, y: 0.5, width: 1, height: 0.5), maximumDimension: 400)
        #expect(try ImageGeometry.read(top.fileURL).upright == PixelSize(width: 400, height: 150))
        let topPixel = try pixel(top.fileURL), bottomPixel = try pixel(bottom.fileURL)
        #expect(topPixel[0] > 220 && topPixel[2] < 30)
        #expect(bottomPixel[2] > 220 && bottomPixel[0] < 30)
        #expect(FileManager.default.fileExists(atPath: lease.fileURL.path))
    }
    private func resolver(_ f: RenderFixture, library: ViewerLibrary, catalog: ViewerCatalog) throws -> VersionImageResolver {
        VersionImageResolver(library: library, catalog: catalog, pool: RenderLibrary(f).pool(),
            rawRenderer: try RawDisplayRenderer(directory: f.root.appendingPathComponent("raw-display")), cache: try f.cache())
    }
    private func saved(_ f: RenderFixture, jpeg: CameraJPEG, availability: AssetAvailability = .available, sourceID: String? = nil) -> SavedVersion {
        SavedVersion(id: UUID(), sourceID: sourceID ?? f.source.id, outputAssetID: "saved-asset", recipeSnapshot: f.recipe, operationID: UUID(), exportedAt: Date(), jpeg: jpeg, availability: availability)
    }
    private func jpegFixture(_ f: RenderFixture) throws -> CameraJPEG {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let data = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).jpegData(withCompressionQuality: 1) { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 400, height: 150))
            UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 150, width: 400, height: 150))
        }
        let url = f.root.appendingPathComponent("viewer-test.JPG"); try data.write(to: url)
        let original = try f.jpeg()
        let key = RenderKey(sourceID: f.source.id, sourceRevision: f.source.resourceRevision, sourceSHA256: f.raw.sha256, settingsDigest: f.recipe.settingsDigest,
            cameraContext: f.context, width: 400, height: 300, orientation: 1, policy: .fullSizeFineRecordedGeometry, quality: .fullResolutionFine)
        return CameraJPEG(fileURL: url, sourceID: key.sourceID, sourceRevision: key.sourceRevision, sourceSHA256: key.sourceSHA256, recipeSnapshotID: f.recipe.id, settingsDigest: key.settingsDigest,
            cameraContext: key.cameraContext, operationID: UUID(), width: 400, height: 300, orientation: 1, quality: .fullResolutionFine, effectiveRecipe: original.effectiveRecipe,
            baselineSHA256: "synthetic", candidateSHA256: "synthetic", outputSHA256: try ResourceChecksum.sha256(url), key: key)
    }
    private func pixel(_ url: URL) throws -> [UInt8] {
        let image = try #require(UIImage(contentsOfFile: url.path)?.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes
    }
}

private final class ViewerProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []
    func add(_ value: Double) { lock.withLock { recorded.append(value) } }
    var values: [Double] { lock.withLock { recorded } }
}
private actor ViewerLibrary: PhotoLibraryReading {
    let original: URL
    var tokens: [ResourceToken]
    var requestedAssets: [String] = [], materialized: [ResourceToken] = [], transferred: [URL] = []
    var failure: ResourceError?
    init(original: URL, tokens: [ResourceToken]) { self.original = original; self.tokens = tokens }
    func setTokens(_ tokens: [ResourceToken]) { self.tokens = tokens }
    func setFailure(_ failure: ResourceError) { self.failure = failure }
    func requestAccess() -> LibraryAccess { .full }
    func sources() -> AsyncThrowingStream<[PhotoSource], Error> { AsyncThrowingStream { $0.finish() } }
    func source(id: SourceID) throws -> PhotoSource { throw ResourceError.inaccessibleAsset(id) }
    func resources(assetID: String) throws -> [ResourceToken] { requestedAssets.append(assetID); if let failure { throw failure }; return tokens }
    func changes() -> AsyncStream<LibraryChange> { AsyncStream { $0.finish() } }
    func materialize(_ token: ResourceToken, progress: @escaping @Sendable (Double) -> Void) throws -> LocalResource {
        materialized.append(token); progress(0.25)
        let url = original.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".JPG")
        try FileManager.default.copyItem(at: original, to: url); transferred.append(url); progress(1)
        return LocalResource(token: token, fileURL: url, checksum: try ResourceChecksum.sha256(url))
    }
}
private actor ViewerCatalog: CatalogStoring {
    let saved: [SavedVersion]
    var sourceIDs: [String] = []
    init(_ saved: [SavedVersion]) { self.saved = saved }
    func versions(sourceID: SourceID) -> [SavedVersion] { sourceIDs.append(sourceID); return saved }
    func upsertSources(_ sources: [PhotoSource]) throws { throw ViewerError.invalidVersion }
    func replaceRecipes(_ snapshots: ImportedRecipeCollection) throws { throw ViewerError.invalidVersion }
    func latestRecipeSlots() throws -> [RecipeSlot] { [] }
    func recipes(camera: CameraExecutionContext) -> [RecipeSnapshot] { [] }
    func latestRecipes() -> [RecipeSnapshot] { [] }
    func updatePhoneRecipe(_ draft: PhoneRecipeDraft) throws -> PhoneRecipe { throw ViewerError.invalidVersion }
    func phoneRecipes() -> [PhoneRecipe] { [] }
    func copyRecipeToPhone(_ recipe: RecipeSnapshot) throws -> PhoneRecipe { throw ViewerError.invalidVersion }
    func deletePhoneRecipe(id: UUID) throws { throw ViewerError.invalidVersion }
    func saveJob(_ job: ExportJob) throws { throw ViewerError.invalidVersion }
    func job(id: UUID) throws -> ExportJob { throw ViewerError.invalidVersion }
    func unfinishedJobs() -> [ExportJob] { [] }
    func confirmSaved(jobID: UUID, operationID: UUID, version: SavedVersion) throws { throw ViewerError.invalidVersion }
    func setAvailability(assetID: String, availability: AssetAvailability) throws { throw ViewerError.invalidVersion }
}
