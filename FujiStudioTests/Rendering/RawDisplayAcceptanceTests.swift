import Foundation
import Testing
@testable import FujiStudio

@MainActor struct RawDisplayAcceptanceTests {
    @Test func absentFlagAndConflictingFlagNeverReadOrMaterialize() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let reader = RenderLibrary(f)
        for arguments in [["FujiStudio"], ["--raw-display-acceptance-probe", "--xt5-production-acceptance-probe"]] {
            let output = f.root.appendingPathComponent(UUID().uuidString)
            let runner = RawDisplayAcceptanceRunner(directory: output, reader: reader)
            await runner.runIfRequested(arguments: arguments)
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
        #expect(await reader.count == 0)
    }
    @Test func missingRetainedSourceFailsExplicitlyWithoutFallbackOrMaterialization() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let output = f.root.appendingPathComponent("documents"), reader = RenderLibrary(f)
        let runner = RawDisplayAcceptanceRunner(directory: output, reader: reader)
        await runner.runIfRequested(arguments: ["--raw-display-acceptance-probe"])
        let report = try report(output)
        #expect(report["outcome"] as? String == "inputUnavailable")
        #expect(report["complete"] as? Bool == false)
        #expect(await reader.count == 0)
    }
    @Test func changedRevisionAndMissingPairFailBeforeDownload() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let reader = RenderLibrary(f)
        for revision in ["v1", "changed"] {
            let output = f.root.appendingPathComponent(UUID().uuidString)
            let raw = PreparedRAW(fileURL: f.raw.fileURL, sha256: f.raw.sha256, sourceID: f.raw.sourceID, sourceRevision: revision, metadata: f.raw.metadata)
            let binding = RetainedRAWSource(raw: raw, rafRole: .primaryOriginal, jpegRole: .alternateOriginal, originalFilename: f.token.originalFilename,
                manifestURL: f.root.appendingPathComponent("manifest.json"), protocolURL: f.root.appendingPathComponent("protocol.json"))
            let runner = RawDisplayAcceptanceRunner(directory: output, reader: reader, load: { _ in binding })
            await runner.runIfRequested(arguments: ["--raw-display-acceptance-probe"])
            #expect(try report(output)["outcome"] as? String == "inputUnavailable")
        }
        #expect(await reader.count == 0)
    }
    @Test func retainedLoaderRejectsAbsentMultipleAndMissingProtocol() throws {
        let f = try RenderFixture(); defer { f.remove() }
        let root = f.root.appendingPathComponent("retained")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try RetainedProductionAcceptanceInputs.loadSource(root: root, paired: true) }
        for _ in 0..<2 {
            let run = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
            try Data([0]).write(to: run.appendingPathComponent("source.RAF"))
            try Data("{}".utf8).write(to: run.appendingPathComponent("source-manifest.json"))
            #expect(throws: (any Error).self) { try RetainedProductionAcceptanceInputs.loadSource(root: root, paired: true) }
        }
    }
    private func report(_ root: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("raw-display-acceptance-evidence.json"))) as? [String: Any])
    }
}

extension RawDisplayAcceptanceTests {
    @Test func exactLivePairHashIsCheckedAndDecoderFailureRemainsSeparateFromCameraSupport() async throws {
        let f = try RenderFixture(); defer { f.remove() }
        let reader = RenderLibrary(f)
        let jpeg = ResourceToken(assetID: f.source.id, role: .alternateOriginal, contentTypeIdentifier: "public.jpeg", format: .jpeg, originalFilename: "paired.JPG", discriminator: "jpeg", sourceRevision: f.source.resourceRevision)
        await reader.setSource(PhotoSource(id: f.source.id, originalResources: .init(raf: f.token, jpeg: jpeg), captureDate: nil, location: nil, resourceRevision: f.source.resourceRevision))
        let manifest = f.root.appendingPathComponent("private-manifest.json"), proto = f.root.appendingPathComponent("private-protocol.json")
        try Data("{}".utf8).write(to: manifest); try Data("{}".utf8).write(to: proto)
        for matching in [false, true] {
            let raw = PreparedRAW(fileURL: f.raw.fileURL, sha256: matching ? f.raw.sha256 : "wrong-retained-hash", sourceID: f.raw.sourceID, sourceRevision: f.raw.sourceRevision, metadata: f.raw.metadata)
            let binding = RetainedRAWSource(raw: raw, rafRole: .primaryOriginal, jpegRole: .alternateOriginal, originalFilename: f.token.originalFilename, manifestURL: manifest, protocolURL: proto)
            let output = f.root.appendingPathComponent(UUID().uuidString)
            let runner = RawDisplayAcceptanceRunner(directory: output, reader: reader, pool: reader.pool(), load: { _ in binding })
            await runner.runIfRequested(arguments: ["--raw-display-acceptance-probe"])
            let bytes = try Data(contentsOf: output.appendingPathComponent("raw-display-acceptance-evidence.json"))
            let report = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(report["outcome"] as? String == (matching ? "rawDisplayUnavailable" : "inputUnavailable"))
            #expect(report["complete"] as? Bool == false)
            #expect(!String(decoding: bytes, as: UTF8.self).contains(f.source.id))
            #expect(!String(decoding: bytes, as: UTF8.self).contains(f.raw.sha256))
            #expect(await reader.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        }
        #expect(await reader.count == 2)
    }
}

extension RawDisplayAcceptanceTests {
    @Test func retainedLoaderValidatesUniquePairProtocolHashGeometryAndOriginalRoles() throws {
        let f = try RenderFixture(); defer { f.remove() }
        let fixture = try RetainedRAWFixture(directory: f.root.appendingPathComponent("retained"))
        let source = try RetainedProductionAcceptanceInputs.loadSource(root: fixture.root, paired: true)
        #expect(source.raw.sourceID == "synthetic-pair" && source.raw.sha256 == fixture.hash)
        #expect(source.rafRole == .alternateOriginal && source.jpegRole == .primaryOriginal)
        #expect(source.raw.metadata.orientation == 6 && source.raw.metadata.recordedGeometry.width == 7728)
        let proto = fixture.run.appendingPathComponent("protocol-manifest.json")
        try JSONSerialization.data(withJSONObject: ["sourceSHA256": "mismatch"]).write(to: proto)
        #expect(throws: CameraServiceError.sourceChanged) { try RetainedProductionAcceptanceInputs.loadSource(root: fixture.root, paired: true) }
        try JSONSerialization.data(withJSONObject: ["sourceSHA256": fixture.hash]).write(to: proto)
        let manifestURL = fixture.run.appendingPathComponent("source-manifest.json")
        let original = try Data(contentsOf: manifestURL)
        for (field, value) in [("resourceRole", "adjusted"), ("jpegResourceRole", "alternateOriginal"), ("jpegSourceRevision", "changed")] {
            var manifest = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any]); manifest[field] = value
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
            #expect(throws: CameraServiceError.sourceChanged) { try RetainedProductionAcceptanceInputs.loadSource(root: fixture.root, paired: true) }
        }
        try original.write(to: manifestURL)
        _ = try RetainedRAWFixture(directory: fixture.root)
        #expect(throws: CameraServiceError.sourceChanged) { try RetainedProductionAcceptanceInputs.loadSource(root: fixture.root, paired: true) }
    }
}
