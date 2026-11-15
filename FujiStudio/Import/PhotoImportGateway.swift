import Foundation

protocol PhotoImportGateway: Sendable {
    /// The caller must durably record submitting intent and pin the staged files before
    /// entering this operation. The synchronous callback runs inside the Photos change block.
    func create(_ capture: ValidatedCapture,
                onPlaceholder: @escaping @Sendable (String) throws -> Void) async -> PhotoImportOutcome
    /// Preserve a located asset as `.foundUnreadable` if its originals cannot be read.
    func inspect(assetID: String) async throws -> ImportedAssetInspection
    func candidates(for capture: ValidatedCapture) async throws -> [String]
    func candidateSearch(for capture: ValidatedCapture) async throws -> ImportCandidateSearch
}

extension PhotoImportGateway {
    func candidateSearch(for capture: ValidatedCapture) async throws -> ImportCandidateSearch {
        try await .narrow(candidates(for: capture))
    }
}

enum PhotoImportOutcome: Equatable, Sendable {
    case submitted(assetID: String)
    /// No creation was issued. The caller may offer an explicit retry.
    case rejected(PhotoImportFailure)
    /// A creation was issued and could have committed. Reconcile before offering a retry.
    case uncertain(assetID: String?)
}

enum PhotoImportFailure: Error, Equatable, Sendable {
    case authorization, invalidResource, storage, unavailable, missingConfirmation
}

enum ImportedAssetInspection: Equatable, Sendable {
    case found(ImportedAssetSnapshot)
    /// The requested asset was located, and its complete original bytes are unavailable.
    case foundUnreadable
    /// No usable lookup result for the requested identifier.
    case unavailable
    /// An exact identifier miss with full access to the available library.
    case absent
}

enum ImportedResourceRole: Equatable, Hashable, Sendable {
    case primary, alternate, other
}

struct ImportedResourceFingerprint: Equatable, Hashable, Sendable {
    let role: ImportedResourceRole
    let format: ImportOriginalRole?
    let originalFilename: String
    let byteCount: UInt64
    let sha256: String
}

struct ImportedAssetSnapshot: Equatable, Sendable {
    let assetID: String
    let originals: [ImportedResourceFingerprint]

    func matches(_ fingerprints: [ImportOriginalFingerprint]) -> Bool {
        let roles = Set(fingerprints.map(\.role))
        guard originals.count == fingerprints.count, roles.count == fingerprints.count,
              roles == [.raf] || roles == [.raf, .jpeg] else { return false }

        let isPair = roles.contains(.jpeg)
        let expected = fingerprints.map { fingerprint in
            ImportedResourceFingerprint(role: isPair && fingerprint.role == .raf ? .alternate : .primary,
                format: fingerprint.role, originalFilename: fingerprint.originalFilename,
                byteCount: fingerprint.byteCount, sha256: fingerprint.sha256)
        }
        return Set(originals) == Set(expected)
    }
}

enum ImportCandidateSearch: Equatable, Sendable {
    /// A search that can locate matches but has no proof of completeness.
    case narrow([String])
    /// The gateway has full access and evidence that the available result covers all
    /// possible assets from the interrupted submission. Native metadata queries are narrow.
    case authoritative([String])

    var assetIDs: [String] {
        switch self {
        case .narrow(let ids), .authoritative(let ids): ids
        }
    }

    var isAuthoritative: Bool {
        if case .authoritative = self { return true }
        return false
    }
}
