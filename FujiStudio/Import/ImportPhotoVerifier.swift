import Foundation

enum ImportReconciliation: Equatable, Sendable {
    case verified(ImportReceipt)
    case definitivelyAbsent
    case savedUnverified(String?)
    case uncertain
}

struct ImportPhotoVerifier: Sendable {
    let gateway: any PhotoImportGateway

    func reconcile(capture: ValidatedCapture, placeholder: String?, recheckingSettledSave: Bool = false) async -> ImportReconciliation {
        let expected = capture.originals.map(\.fingerprint)
        var inspectedPlaceholder: ImportedAssetInspection?
        if let placeholder {
            let inspection = await inspect(placeholder)
            inspectedPlaceholder = inspection
            switch inspection {
            case .found(let snapshot):
                return snapshot.matches(expected)
                    ? receipt(assetID: placeholder, capture: capture, originals: expected)
                    : .savedUnverified(placeholder)
            case .foundUnreadable:
                return .savedUnverified(placeholder)
            case .absent, .unavailable:
                break
            }
        }

        let unresolved: ImportReconciliation = placeholder.map { .savedUnverified($0) } ?? .uncertain
        guard let search = try? await gateway.candidateSearch(for: capture), !Task.isCancelled else {
            return unresolved
        }

        var hasUnreadableCandidate = false
        var hasFoundCandidate = false
        var match: String?
        for id in Set(search.assetIDs) where id != placeholder {
            guard !Task.isCancelled else { return unresolved }
            switch await inspect(id) {
            case .found(let snapshot):
                hasFoundCandidate = true
                if snapshot.matches(expected) {
                    guard match == nil else { return .uncertain }
                    match = id
                }
            case .absent:
                break
            case .foundUnreadable, .unavailable:
                hasUnreadableCandidate = true
            }
        }

        guard !Task.isCancelled, !hasUnreadableCandidate else { return unresolved }
        if let match { return receipt(assetID: match, capture: capture, originals: expected) }
        // A found but incomplete asset could be a partially retained submission.
        // PhotoKit assigns the finished asset the same ID as its placeholder. A second
        // full-access lookup of that exact ID can settle an already paused save.
        let settledIDIsMissing = recheckingSettledSave && inspectedPlaceholder == .absent
        if !hasFoundCandidate, inspectedPlaceholder != .unavailable, search.isAuthoritative || settledIDIsMissing {
            return .definitivelyAbsent
        }
        return unresolved
    }

    private func inspect(_ id: String) async -> ImportedAssetInspection {
        guard !id.isEmpty, let inspection = try? await gateway.inspect(assetID: id), !Task.isCancelled else {
            return .unavailable
        }
        if case .found(let snapshot) = inspection, snapshot.assetID != id { return .unavailable }
        return inspection
    }

    private func receipt(assetID: String, capture: ValidatedCapture,
                         originals: [ImportOriginalFingerprint]) -> ImportReconciliation {
        .verified(.init(captureID: capture.selection.captureID, fingerprints: originals,
                        assetID: assetID, verifiedAt: Date()))
    }
}
