import Foundation
import ImageIO
import Photos
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import FujiCameraCore
@testable import FujiStudio

@MainActor struct PhotoLibraryEditorTests {
    // A new-asset write, losing the marker/recipe, or ignoring RAW-only sources breaks this.
    @Test(arguments: [false, true])
    func editsExistingAssetAndKeepsOriginals(_ paired: Bool) async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try editJPEGFixture(f)
        var source = f.source
        if paired {
            source = PhotoSource(id: source.id, originalResources: .init(raf: f.token,
                jpeg: .init(assetID: source.id, role: .alternateOriginal, contentTypeIdentifier: "public.jpeg",
                    format: .jpeg, originalFilename: "camera.JPG", discriminator: "jpeg")),
                captureDate: nil, location: nil, resourceRevision: source.resourceRevision)
        }
        let gateway = TestPhotoEditGateway(root: f.root, assetID: source.id)
        let operation = UUID(), request = PhotoSaveRequest(jpeg: jpeg, operationID: operation, captureDate: nil, location: nil)
        let saved = try await PhotoLibraryEditor(gateway: gateway).saveJPEG(request,
            edit: .init(source: source, recipe: f.recipe)) { _ in }
        #expect(saved.assetID == source.id && saved.operationID == operation)
        #expect(gateway.source?.originalResources == source.originalResources)
        #expect(gateway.session.adjustment?.operationID == operation)
        #expect(gateway.session.adjustment?.sourceID == source.id)
        #expect(gateway.session.adjustment?.recipe == f.recipe)
        #expect(gateway.session.geometry == ImageGeometry(encoded: .init(width: 40, height: 20), orientation: 1))
        #expect(try ResourceChecksum.sha256(jpeg.fileURL) == jpeg.outputSHA256)
        #expect(!FileManager.default.fileExists(atPath: gateway.session.renderedContentURL.path))
    }

    @Test func rotatedOutputIsUprightAndPreservesColorOrientation() throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try editJPEGFixture(f, orientation: 6), url = f.root.appendingPathComponent("upright.JPG")
        try PhotoEditJPEG.write(jpeg, to: url)
        #expect(try ImageGeometry.read(url) == ImageGeometry(encoded: .init(width: 20, height: 40), orientation: 1))
        let image = try #require(UIImage(contentsOfFile: url.path)?.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4 * 20 * 40)
        let context = try #require(CGContext(data: &bytes, width: 20, height: 40, bitsPerComponent: 8,
            bytesPerRow: 80, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 20, height: 40))
        // The red top half rotates onto the right, with blue on the left.
        #expect(bytes[(20 * 20 + 15) * 4] > 200)
        #expect(bytes[(20 * 20 + 4) * 4 + 2] > 200)
    }

    @Test func deniedOrUneditableSourceDoesNotSubmit() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try editJPEGFixture(f), gateway = TestPhotoEditGateway(root: f.root, assetID: f.source.id)
        gateway.accessValue = .denied
        await #expect(throws: PhotoLibraryWriteError.authorization(.denied)) {
            try await PhotoLibraryEditor(gateway: gateway).saveJPEG(
                .init(jpeg: jpeg, operationID: UUID(), captureDate: nil, location: nil),
                edit: .init(source: f.source, recipe: f.recipe)) { _ in }
        }
        #expect(gateway.session.commits == 0)
        gateway.accessValue = .full; gateway.prepareFailure = .invalidOutput("Asset cannot be edited")
        await #expect(throws: PhotoLibraryWriteError.invalidOutput("Asset cannot be edited")) {
            try await PhotoLibraryEditor(gateway: gateway).saveJPEG(
                .init(jpeg: jpeg, operationID: UUID(), captureDate: nil, location: nil),
                edit: .init(source: f.source, recipe: f.recipe)) { _ in }
        }
        #expect(gateway.session.commits == 0)
    }

    @Test func recoveryRequiresExactCurrentOperationAndSource() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let gateway = TestPhotoEditGateway(root: f.root, assetID: f.source.id), editor = PhotoLibraryEditor(gateway: gateway)
        let operation = UUID()
        gateway.marker = .init(operationID: operation, sourceID: f.source.id, recipe: f.recipe)
        #expect(try await editor.findExport(operationID: operation, sourceID: f.source.id)
            == .found(.init(assetID: f.source.id, operationID: operation, photosGeometry: nil)))
        #expect(try await editor.findExport(operationID: UUID(), sourceID: f.source.id) == .notFound)
        #expect(try await editor.findExport(operationID: operation, sourceID: "other") == .notFound)
        gateway.marker = nil
        #expect(try await editor.findExport(operationID: operation, sourceID: f.source.id) == .notFound)
        gateway.accessValue = .denied
        #expect(try await editor.findExport(operationID: operation, sourceID: f.source.id) == .inaccessible)
        #expect(gateway.session.commits == 0)
    }

    @Test func cancelledSubmissionWaitsForPhotosAndRejectsActualFailure() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let jpeg = try editJPEGFixture(f), gateway = TestPhotoEditGateway(root: f.root, assetID: f.source.id)
        gateway.session.hold = true
        let task = Task {
            try await PhotoLibraryEditor(gateway: gateway).saveJPEG(
                .init(jpeg: jpeg, operationID: UUID(), captureDate: nil, location: nil),
                edit: .init(source: f.source, recipe: f.recipe)) { _ in }
        }
        while gateway.session.commits == 0 { await Task.yield() }
        task.cancel()
        #expect(FileManager.default.fileExists(atPath: gateway.session.renderedContentURL.path))
        gateway.session.finish(false, NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.notEnoughSpace.rawValue))
        await #expect(throws: PhotoLibraryWriteError.rejected(.insufficientStorage)) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: gateway.session.renderedContentURL.path))
    }
}

final class TestPhotoEditGateway: PhotoEditGateway, @unchecked Sendable {
    var accessValue: LibraryAccess = .full
    var source: PhotoSource?
    var prepareFailure: PhotoLibraryWriteError?
    var marker: PhotoEditAdjustment?
    let session: TestPhotoEditSession
    init(root: URL, assetID: String) { session = .init(root: root, assetID: assetID) }
    func access() async -> LibraryAccess { accessValue }
    func prepare(source: PhotoSource) async throws -> any PhotoEditingSession {
        if let prepareFailure { throw prepareFailure }; self.source = source; return session
    }
    func currentAdjustment(assetID: String) async throws -> PhotoEditAdjustment? { marker }
}

final class TestPhotoEditSession: PhotoEditingSession, @unchecked Sendable {
    let assetID: String, renderedContentURL: URL
    private let lock = NSLock()
    private var completion: (@Sendable (Bool, NSError?) -> Void)?
    private var count = 0
    var commits: Int { lock.withLock { count } }
    var hold = false
    var adjustment: PhotoEditAdjustment?
    var geometry: ImageGeometry?
    init(root: URL, assetID: String) { self.assetID = assetID; renderedContentURL = root.appendingPathComponent("edited.JPG") }
    func commit(adjustment: PhotoEditAdjustment, completion: @escaping @Sendable (Bool, NSError?) -> Void) throws {
        self.adjustment = adjustment; geometry = try ImageGeometry.read(renderedContentURL)
        lock.withLock { self.completion = completion; count += 1 }
        if !hold { finish(true, nil) }
    }
    func finish(_ success: Bool, _ error: NSError?) {
        let callback = lock.withLock { let c = completion; completion = nil; return c }; callback?(success, error)
    }
}

@MainActor func editJPEGFixture(_ f: RenderFixture, orientation: Int = 1) throws -> CameraJPEG {
    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
    let image = UIGraphicsImageRenderer(size: .init(width: 40, height: 20), format: format).image { c in
        UIColor.red.setFill(); c.fill(.init(x: 0, y: 0, width: 40, height: 10))
        UIColor.blue.setFill(); c.fill(.init(x: 0, y: 10, width: 40, height: 10))
    }
    let url = f.root.appendingPathComponent(UUID().uuidString + ".JPG")
    let out = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(out, try #require(image.cgImage), [kCGImagePropertyOrientation: orientation] as CFDictionary)
    #expect(CGImageDestinationFinalize(out))
    let base = try f.jpeg()
    let key = RenderKey(sourceID: f.source.id, sourceRevision: f.source.resourceRevision, sourceSHA256: f.raw.sha256,
        settingsDigest: f.recipe.settingsDigest, cameraContext: f.context, width: 40, height: 20, orientation: orientation,
        policy: .fullSizeFineRecordedGeometry, quality: .fullResolutionFine)
    return CameraJPEG(fileURL: url, sourceID: key.sourceID, sourceRevision: key.sourceRevision, sourceSHA256: key.sourceSHA256,
        recipeSnapshotID: f.recipe.id, settingsDigest: key.settingsDigest, cameraContext: key.cameraContext, operationID: UUID(),
        width: 40, height: 20, orientation: orientation, quality: .fullResolutionFine, effectiveRecipe: base.effectiveRecipe,
        baselineSHA256: "fixture", candidateSHA256: "fixture", outputSHA256: try ResourceChecksum.sha256(url), key: key)
}
