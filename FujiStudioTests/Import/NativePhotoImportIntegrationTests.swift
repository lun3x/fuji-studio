import Foundation
import FujiCameraCore
import Photos
import XCTest
@testable import FujiStudio

/// Opt in on an isolated simulator by provisioning Library/Caches/NativePhotoImportFixtures
/// in the test host's data container and granting read/write Photos access there.
@MainActor
final class NativePhotoImportIntegrationTests: XCTestCase {
    func testPairCreatesOneAssetAndReadbackRequiresBothOriginals() async throws {
        let inputs = try fixtureDirectory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ImportStagingStore(root: root)
        let stem = "FujiStudio-NativePair-\(UUID().uuidString)"
        let resources = [
            FixtureOriginal(file: inputs.appendingPathComponent("X-T5.RAF"), filename: stem + ".RAF",
                            role: .raf, width: 7728, height: 5152, byteCount: 43_113_376,
                            sha256: "b2a067e7fda16338f15c2532caa12b238b2415dc1c75a96a6d24d3445cfd0ae3"),
            // Companion extracted from the RAF preview. This tests native resource mechanics.
            FixtureOriginal(file: inputs.appendingPathComponent("X-T5-embedded.JPG"), filename: stem + ".JPG",
                            role: .jpeg, width: 4416, height: 2944, byteCount: 4_016_595,
                            sha256: "80f410d7f09c1d9fbd902c9c0bf52b859aa0ada585d8e6e17aa517d0b27daab4")
        ]
        let capture = try makeCapture(resources, model: .xt5, stagingRoot: root)
        try await assertSaved(capture, store: store, expected: resources)
    }

    func testStandaloneRAFReadbackPreservesExactOriginal() async throws {
        let inputs = try fixtureDirectory()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ImportStagingStore(root: root)
        let resources = [
            FixtureOriginal(file: inputs.appendingPathComponent("X-E3.RAF"),
                            filename: "FujiStudio-NativeRAW-\(UUID().uuidString).RAF",
                            role: .raf, width: 6000, height: 4000, byteCount: 27_799_280,
                            sha256: "03d6e79ae79107c51d0e1c1c9e488a0ab20268cd9fe43f47d8ea3ea310df35c6")
        ]
        let capture = try makeCapture(resources, model: .xe3, stagingRoot: root)
        try await assertSaved(capture, store: store, expected: resources)
    }

    private func fixtureDirectory() throws -> URL {
        #if targetEnvironment(simulator)
        let caches = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        let directory = caches.appendingPathComponent("NativePhotoImportFixtures", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("RUN").path) else {
            throw XCTSkip("Provision public RAF inputs and RUN in the isolated simulator to exercise native PhotoKit.")
        }
        XCTAssertEqual(PHPhotoLibrary.authorizationStatus(for: .readWrite), .authorized)
        return directory
        #else
        throw XCTSkip("Native import fixtures run on an isolated simulator.")
        #endif
    }

    private func makeCapture(_ resources: [FixtureOriginal], model: WirelessCameraModel,
                             stagingRoot: URL) throws -> ValidatedCapture {
        let camera = WirelessIdentity(cameraID: .init(), model: model, firmware: nil)
        let sessionID = UUID()
        let originals = try resources.enumerated().map { index, fixture in
            XCTAssertEqual(try ResourceChecksum.sha256(fixture.file), fixture.sha256)
            let relativePath = UUID().uuidString + "." + fixture.role.fileExtension
            let local = stagingRoot.appendingPathComponent(relativePath)
            try FileManager.default.copyItem(at: fixture.file, to: local)
            let object = WirelessObjectDescriptor(cameraID: camera.cameraID, sessionID: sessionID, storageID: 1,
                handle: UInt32(index + 1), directory: "DCIM/100_FUJI", filename: fixture.filename,
                format: fixture.role == .raf ? .raf : .jpeg, byteLength: fixture.byteCount,
                captureDate: "20200102T030405+0000", dimensions: .init(width: fixture.width, height: fixture.height))
            let metadata = try OriginalImportValidator.inspect(file: local, object: object)
            return StagedOriginal(relativePath: relativePath,
                fingerprint: .init(role: fixture.role, originalFilename: fixture.filename,
                                   byteCount: fixture.byteCount, sha256: fixture.sha256),
                metadata: metadata, descriptor: object, verifiedTransferMode: .xApp)
        }
        let descriptors = originals.map(\.descriptor)
        let selection = ImportSelection(captureID: .init(describing: descriptors), camera: camera,
                                        descriptors: descriptors, policy: resources.count == 2 ? .pair : .rawOnly)
        return .init(selection: selection, originals: originals,
                     metadata: .init(creationDate: Date(timeIntervalSince1970: 1_577_934_245), dateSource: .objectInfo,
                                     location: .init(latitude: 52.25, longitude: 4.5)))
    }

    private func assertSaved(_ capture: ValidatedCapture, store: ImportStagingStore,
                             expected: [FixtureOriginal]) async throws {
        let gateway = NativePhotoImportGateway(staging: store)
        let root = try store.fileURL(for: capture.originals[0]).deletingLastPathComponent()
        let journal = try ImportJournal(root: root.appendingPathComponent("journal"))
        var job = try ImportJob(selections: [capture.selection], importDate: capture.metadata.creationDate)
        job.captures[0].originals = capture.originals
        job.captures[0].stage = .submitting
        let submitted = try await journal.save(job)
        let writer = journal.placeholderWriter
        let outcome = await gateway.create(capture) { id in
            try writer.persistPlaceholder(jobID: submitted.id, captureID: capture.selection.captureID, assetID: id)
        }
        guard case .submitted(let id) = outcome else { return XCTFail("PhotoKit settlement: \(outcome)") }
        let persisted = try await journal.loadJobs()
        XCTAssertEqual(persisted.first?.captures.first?.placeholderAssetID, id)
        let candidates = try await gateway.candidates(for: capture)
        XCTAssertEqual(candidates, [id], "Creation allocates one asset for the capture")
        for original in capture.originals {
            XCTAssertEqual(try ResourceChecksum.sha256(store.fileURL(for: original)), original.sha256)
        }

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        XCTAssertEqual(fetch.count, 1)
        let asset = try XCTUnwrap(fetch.firstObject)
        XCTAssertEqual(try XCTUnwrap(asset.creationDate).timeIntervalSince1970,
                       capture.metadata.creationDate.timeIntervalSince1970, accuracy: 0.001)
        let location = try XCTUnwrap(asset.location)
        XCTAssertEqual(location.coordinate.latitude, 52.25, accuracy: 0.0001)
        XCTAssertEqual(location.coordinate.longitude, 4.5, accuracy: 0.0001)
        if expected.count == 2 { XCTAssertEqual(asset.originalResourceChoice, .compressed) }

        // Read actual Photos file bytes independently of the gateway's streaming hash.
        let resources = PHAssetResource.assetResources(for: asset).filter { $0.type == .photo || $0.type == .alternatePhoto }
        XCTAssertEqual(resources.count, expected.count)
        for fixture in expected {
            let type: PHAssetResourceType = expected.count == 2 && fixture.role == .raf ? .alternatePhoto : .photo
            let resource = try XCTUnwrap(resources.first { $0.type == type && $0.filename == fixture.filename })
            let output = root.appendingPathComponent(UUID().uuidString)
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: output, options: nil)
            let count = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize
            let hash = try ResourceChecksum.sha256(output)
            XCTAssertEqual(count.flatMap(UInt64.init(exactly:)), fixture.byteCount)
            XCTAssertEqual(hash, fixture.sha256)
            print("Native PhotoKit type=\(type.rawValue) bytes=\(count ?? -1) sha256=\(hash)")
        }

        let verifier = ImportPhotoVerifier(gateway: gateway)
        for placeholder in [id, nil] {
            let reconciliation = await verifier.reconcile(capture: capture, placeholder: placeholder)
            guard case .verified(let receipt) = reconciliation else {
                return XCTFail("Native original verification: \(reconciliation)")
            }
            XCTAssertEqual(receipt.assetID, id)
        }
    }
}

private struct FixtureOriginal {
    let file: URL
    let filename: String
    let role: ImportOriginalRole
    let width: Int
    let height: Int
    let byteCount: UInt64
    let sha256: String
}
