import Foundation
import XCTest
@testable import FujiStudio

@MainActor
final class ImportPhotoVerifierTests: XCTestCase {
    func testProcessDeathBeforePlaceholderPersistenceFindsMatchingCandidate() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let (_, capture) = try await fixture.validatedForPhotos()
        let photos = ImportReadback(assets: ["saved": pair(capture, id: "saved")], search: .narrow(["saved"]))

        let result = await ImportPhotoVerifier(gateway: photos).reconcile(capture: capture, placeholder: nil)

        guard case .verified(let receipt) = result else { return XCTFail("Expected full candidate evidence") }
        XCTAssertEqual(receipt.captureID, capture.selection.captureID)
        XCTAssertEqual(receipt.assetID, "saved")
        XCTAssertEqual(receipt.fingerprints, capture.originals.map(\.fingerprint))
    }

    func testCompletionLossAfterDurablePlaceholderVerifiesBeforeSearching() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let (_, capture) = try await fixture.validatedForPhotos()
        let photos = ImportReadback(assets: ["placeholder": pair(capture, id: "placeholder"),
                                           "duplicate": pair(capture, id: "duplicate")],
                                   search: .narrow(["placeholder", "duplicate"]))

        let result = await ImportPhotoVerifier(gateway: photos).reconcile(capture: capture, placeholder: "placeholder")

        guard case .verified(let receipt) = result else { return XCTFail("Expected exact placeholder to take priority") }
        XCTAssertEqual(receipt.assetID, "placeholder")
        let searchCount = await photos.searchCount
        XCTAssertEqual(searchCount, 0)
    }

    func testUnavailablePlaceholderCanBeRecoveredThroughCandidateEvidence() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let (_, capture) = try await fixture.validatedForPhotos()
        let photos = ImportReadback(assets: ["earlier-ID": .unavailable, "saved": pair(capture, id: "saved")],
                                   search: .narrow(["saved"]))
        let result = await ImportPhotoVerifier(gateway: photos).reconcile(capture: capture, placeholder: "earlier-ID")

        guard case .verified(let receipt) = result else { return XCTFail("Expected fully inspected candidate") }
        XCTAssertEqual(receipt.assetID, "saved")
    }

    func testLimitedVisibilityKeepsAPlaceholderUnverified() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let (_, capture) = try await fixture.validatedForPhotos()
        let photos = ImportReadback(assets: ["possibly-saved": .unavailable], search: .narrow([]))

        let verifier = ImportPhotoVerifier(gateway: photos)
        let result = await verifier.reconcile(capture: capture, placeholder: "possibly-saved")
        let noPlaceholder = await verifier.reconcile(capture: capture, placeholder: nil)
        XCTAssertEqual(result, .savedUnverified("possibly-saved"))
        XCTAssertEqual(noPlaceholder, .uncertain)
    }

    func testCancelledOrLostSubmissionCannotTurnAFilteredMissIntoAbsence() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let (_, capture) = try await fixture.validatedForPhotos()
        let photos = ImportReadback(assets: ["possibly-saved": .absent], search: .narrow([]))
        let verifier = ImportPhotoVerifier(gateway: photos)

        let result = await verifier.reconcile(capture: capture, placeholder: "possibly-saved")
        let noPlaceholder = await verifier.reconcile(capture: capture, placeholder: nil)
        XCTAssertEqual(result, .savedUnverified("possibly-saved"))
        XCTAssertEqual(noPlaceholder, .uncertain)
    }

    func testOnlyACompleteSuccessfulSearchCanEstablishAbsence() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let (_, capture) = try await fixture.validatedForPhotos()
        let photos = ImportReadback(assets: ["placeholder": .absent, "removed-candidate": .absent],
                                   search: .authoritative(["removed-candidate"]))

        let result = await ImportPhotoVerifier(gateway: photos).reconcile(capture: capture, placeholder: "placeholder")

        XCTAssertEqual(result, .definitivelyAbsent)
    }

    func testIncompleteCandidateInCompleteSearchCannotProveSubmissionAbsent() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let (_, capture) = try await fixture.validatedForPhotos()
        let jpeg = resource(capture.originals[1], role: .primary)
        let partial: ImportedAssetInspection = .found(.init(assetID: "partial", originals: [jpeg]))
        let photos = ImportReadback(assets: ["partial": partial], search: .authoritative(["partial"]))

        let result = await ImportPhotoVerifier(gateway: photos).reconcile(capture: capture, placeholder: nil)

        XCTAssertEqual(result, .uncertain)
    }

    func testTwoMatchesWithoutPlaceholderRemainUncertain() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let (_, capture) = try await fixture.validatedForPhotos()
        let photos = ImportReadback(assets: ["first": pair(capture, id: "first"), "second": pair(capture, id: "second")],
                                   search: .authoritative(["first", "second"]))

        let result = await ImportPhotoVerifier(gateway: photos).reconcile(capture: capture, placeholder: nil)

        XCTAssertEqual(result, .uncertain)
    }

    func testUnavailableCloudCandidatePreventsSelectingAnotherMatchOrDeclaringAbsence() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let (_, capture) = try await fixture.validatedForPhotos()
        let photos = ImportReadback(assets: ["first": pair(capture, id: "first")], search: .authoritative(["cloud", "first"]),
                                   failedIDs: ["cloud"])

        let result = await ImportPhotoVerifier(gateway: photos).reconcile(capture: capture, placeholder: nil)

        XCTAssertEqual(result, .uncertain)
    }

    func testExactOriginalRolesLengthsAndHashesAreRequired() async throws {
        let fixture = try ImportFileFixture()
        defer { fixture.cleanUp() }
        let (_, capture) = try await fixture.validatedForPhotos()
        let raw = resource(capture.originals[0], role: .alternate)
        let jpeg = resource(capture.originals[1], role: .primary)
        let wrongHash = resource(capture.originals[0], role: .alternate, hash: String(repeating: "0", count: 64))
        let wrongLength = resource(capture.originals[0], role: .alternate, length: raw.byteCount + 1)
        let wrongRole = resource(capture.originals[0], role: .primary)
        let extra = resource(capture.originals[0], role: .other)
        for originals in [[jpeg], [raw], [jpeg, wrongHash], [jpeg, wrongLength], [jpeg, wrongRole], [raw, jpeg, extra]] {
            let photos = ImportReadback(assets: ["partial": .found(.init(assetID: "partial", originals: originals))],
                                       search: .narrow(["partial"]))
            let verifier = ImportPhotoVerifier(gateway: photos)
            let direct = await verifier.reconcile(capture: capture, placeholder: "partial")
            let candidate = await verifier.reconcile(capture: capture, placeholder: nil)
            XCTAssertEqual(direct, .savedUnverified("partial"), "\(originals)")
            XCTAssertEqual(candidate, .uncertain, "\(originals)")
        }
    }

    private func pair(_ capture: ValidatedCapture, id: String) -> ImportedAssetInspection {
        .found(.init(assetID: id, originals: [
            resource(capture.originals[1], role: .primary),
            resource(capture.originals[0], role: .alternate)
        ]))
    }

    private func resource(_ original: StagedOriginal, role: ImportedResourceRole, hash: String? = nil,
                          length: UInt64? = nil) -> ImportedResourceFingerprint {
        .init(role: role, format: original.role, originalFilename: original.originalFilename,
              byteCount: length ?? original.byteCount, sha256: hash ?? original.sha256)
    }
}

private actor ImportReadback: PhotoImportGateway {
    let assets: [String: ImportedAssetInspection]
    let search: ImportCandidateSearch
    let failedIDs: Set<String>
    private(set) var searchCount = 0

    init(assets: [String: ImportedAssetInspection], search: ImportCandidateSearch, failedIDs: Set<String> = []) {
        self.assets = assets
        self.search = search
        self.failedIDs = failedIDs
    }

    func create(_ capture: ValidatedCapture,
                onPlaceholder: @escaping @Sendable (String) throws -> Void) async -> PhotoImportOutcome {
        XCTFail("Reconciliation must be read-only")
        return .uncertain(assetID: nil)
    }

    func inspect(assetID: String) async throws -> ImportedAssetInspection {
        if failedIDs.contains(assetID) { throw CocoaError(.fileReadUnknown) }
        return assets[assetID] ?? .unavailable
    }

    func candidates(for capture: ValidatedCapture) async throws -> [String] { search.assetIDs }

    func candidateSearch(for capture: ValidatedCapture) async throws -> ImportCandidateSearch {
        searchCount += 1
        return search
    }
}
