import CryptoKit
import Foundation
import FujiCameraCore

enum ImportStage: String, Codable, Sendable {
    case queued, downloading, validating, readyToSave, submitting, savedUnverified
    case imported, paused, skipped, failed

    var mayHaveSubmitted: Bool { self == .submitting || self == .savedUnverified }
}

enum ImportPauseReason: String, Codable, Sendable {
    case userRequested, backgrounded, connectionLost, storage, captureFailed, photosAccess, unresolvedSave
}

enum ImportOriginalRole: String, Codable, Hashable, Sendable {
    case raf, jpeg

    init?(_ format: WirelessObjectFormat) {
        switch format {
        case .raf: self = .raf
        case .jpeg: self = .jpeg
        case .other: return nil
        }
    }

    var fileExtension: String { self == .raf ? "raf" : "jpg" }
}

struct ImportOriginalFingerprint: Codable, Hashable, Sendable {
    let role: ImportOriginalRole
    let originalFilename: String
    let byteCount: UInt64
    let sha256: String
}

struct ImportLocation: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    var altitude: Double? = nil
}

struct OriginalImportMetadata: Codable, Equatable, Sendable {
    let cameraModel: String
    let dimensions: PixelSize
    let orientation: Int
    let captureWallTime: String?
    let captureOffset: String?
    let location: ImportLocation?
}

struct StagedOriginal: Codable, Equatable, Sendable {
    let relativePath: String
    let fingerprint: ImportOriginalFingerprint
    let metadata: OriginalImportMetadata
    let descriptor: WirelessObjectDescriptor
    let verifiedTransferMode: WirelessMode

    var originalFilename: String { fingerprint.originalFilename }
    var role: ImportOriginalRole { fingerprint.role }
    var byteCount: UInt64 { fingerprint.byteCount }
    var sha256: String { fingerprint.sha256 }

    func describes(_ object: WirelessObjectDescriptor) -> Bool {
        descriptor.matchesOriginal(object) && originalFilename == object.filename
            && byteCount == object.byteLength && role == ImportOriginalRole(object.format)
    }
}

struct ImportCaptureMetadata: Equatable, Sendable {
    enum DateSource: Equatable, Sendable {
        case embedded, objectInfo, importTimeMissingOffset, importTimeMissingDate
    }

    let creationDate: Date
    let dateSource: DateSource
    let location: ImportLocation?
}

struct ValidatedCapture: Equatable, Sendable {
    let selection: ImportSelection
    let originals: [StagedOriginal]
    let metadata: ImportCaptureMetadata
}

struct ImportReceipt: Codable, Equatable, Sendable {
    let captureID: CameraCaptureID
    let fingerprints: [ImportOriginalFingerprint]
    let assetID: String
    let verifiedAt: Date
}

/// Only the protected journal representation is Codable. Raw protocol keys stay in the
/// live camera binding. A digest keeps stronger observed evidence checkable after relaunch.
struct ImportCameraSnapshot: Codable, Equatable, Sendable {
    let cameraID: WirelessCameraID
    let model: WirelessCameraModel
    private let firmware: String?
    private let mode: WirelessMode?
    private let peerKeyDigest: String?

    init(_ camera: WirelessIdentity, mode: WirelessMode?) {
        cameraID = camera.cameraID
        model = camera.model
        firmware = camera.firmware
        self.mode = mode
        peerKeyDigest = camera.protocolPeerKey.map(Self.digest)
    }

    var redactedIdentity: WirelessIdentity {
        .init(cameraID: cameraID, model: model, firmware: firmware)
    }

    /// The caller must separately admit the live firmware and identify the selected peer.
    /// Stronger evidence is scoped to the observed mode and cannot be silently weakened.
    func matches(_ camera: WirelessIdentity, mode liveMode: WirelessMode) -> Bool {
        guard camera.cameraID == cameraID, camera.model == model else { return false }
        guard let peerKeyDigest else { return true }
        guard mode == nil || mode == liveMode, let key = camera.protocolPeerKey else { return false }
        return Self.digest(key) == peerKeyDigest
    }

    private static func digest(_ key: WirelessProtocolPeerKey) -> String {
        ResourceChecksum.sha256(Data("FujiStudio:wireless-import-peer:1".utf8) + key.bytes)
    }
}

struct ImportCaptureProgress: Equatable, Sendable {
    let selection: ImportSelection
    var stage: ImportStage = .queued
    var originals: [StagedOriginal] = []
    fileprivate(set) var placeholderAssetID: String?
    fileprivate(set) var receipt: ImportReceipt?

    var id: CameraCaptureID { selection.captureID }

    mutating func setPlaceholder(_ assetID: String) throws {
        guard stage.mayHaveSubmitted, !assetID.isEmpty,
              placeholderAssetID == nil || placeholderAssetID == assetID else {
            throw ImportJournalError.invalidTransition
        }
        placeholderAssetID = assetID
    }

    mutating func verify(_ receipt: ImportReceipt) throws {
        guard stage == .readyToSave || stage.mayHaveSubmitted,
              receipt.captureID == id, !receipt.assetID.isEmpty,
              hasCompleteOriginals, Set(receipt.fingerprints) == Set(originals.map(\.fingerprint)),
              receipt.fingerprints.count == originals.count else {
            throw ImportJournalError.invalidTransition
        }
        self.receipt = receipt
        stage = .imported
    }

    var hasCompleteOriginals: Bool { originals.count == selection.descriptors.count }

    func preservesSaveEvidence(from current: Self) -> Bool {
        guard placeholderAssetID == current.placeholderAssetID, receipt == current.receipt else { return false }
        if current.stage.mayHaveSubmitted {
            return stage.mayHaveSubmitted && originals == current.originals
        }
        if current.stage == .imported { return stage == .imported }
        return true
    }
}

struct ImportJob: Equatable, Sendable {
    let id: UUID
    let camera: ImportCameraSnapshot
    let importDate: Date
    private(set) var revision: UInt64
    let frozenSelections: [ImportSelection]
    var captures: [ImportCaptureProgress]
    var pauseReason: ImportPauseReason?

    init(id: UUID = UUID(), selections: [ImportSelection], importDate: Date, mode: WirelessMode? = nil) throws {
        guard let camera = selections.first?.camera,
              selections.allSatisfy({ $0.camera == camera }) else { throw ImportJournalError.invalidJob }
        self.id = id
        self.camera = .init(camera, mode: mode)
        self.importDate = importDate
        revision = 0
        let redacted = self.camera.redactedIdentity
        frozenSelections = selections.map {
            .init(captureID: $0.captureID, camera: redacted, descriptors: $0.descriptors, policy: $0.policy)
        }
        captures = frozenSelections.map { .init(selection: $0) }
        try validate()
    }

    func validate() throws {
        guard importDate.timeIntervalSinceReferenceDate.isFinite,
              !captures.isEmpty, Set(captures.map(\.id)).count == captures.count,
              captures.map(\.selection) == frozenSelections else { throw ImportJournalError.invalidJob }
        var paths: Set<String> = []
        for capture in captures {
            try capture.selection.validateForOriginalImport()
            let objects = capture.selection.descriptors
            let stage = capture.stage
            let requiresAllOriginals = stage.mayHaveSubmitted || stage == .readyToSave
            guard Set(capture.originals.map(\.role)).count == capture.originals.count,
                  capture.originals.allSatisfy({ original in
                      objects.contains(where: original.describes)
                          && ImportStagingStore.isOriginalPath(original.relativePath, role: original.role)
                          && paths.insert(original.relativePath).inserted && Self.isHash(original.sha256)
                  }),
                  !requiresAllOriginals || capture.hasCompleteOriginals,
                  stage.mayHaveSubmitted || stage == .imported || capture.placeholderAssetID == nil,
                  capture.placeholderAssetID?.isEmpty != true,
                  (stage == .imported) == (capture.receipt != nil) else {
                throw ImportJournalError.invalidJob
            }
            if let receipt = capture.receipt {
                guard receipt.captureID == capture.id, !receipt.assetID.isEmpty,
                      receipt.verifiedAt.timeIntervalSinceReferenceDate.isFinite,
                      receipt.fingerprints.count == objects.count,
                      Set(receipt.fingerprints.map(\.role)).count == objects.count,
                      receipt.fingerprints.allSatisfy({ fingerprint in
                          Self.isHash(fingerprint.sha256) && objects.contains { object in
                              fingerprint.role == ImportOriginalRole(object.format)
                                  && fingerprint.byteCount == object.byteLength
                                  && fingerprint.originalFilename == object.filename
                          }
                      }), capture.originals.allSatisfy({ receipt.fingerprints.contains($0.fingerprint) }) else {
                    throw ImportJournalError.invalidJob
                }
            }
        }
    }

    func replacingRevision(_ revision: UInt64) -> Self {
        var copy = self
        copy.revision = revision
        return copy
    }

    fileprivate static func isHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Persistence intentionally encodes only the protected camera snapshot and the fields
    /// required to recover each capture. Descriptors hold evidence, including old routes
    /// for diagnosis. Their session-local handle is never a reconnect credential.
    struct Snapshot: Codable {
        let id: UUID
        let camera: ImportCameraSnapshot
        let importDate: Date
        let revision: UInt64
        let captures: [Capture]
        let pauseReason: ImportPauseReason?

        struct Capture: Codable {
            let id: CameraCaptureID
            let descriptors: [WirelessObjectDescriptor]
            let policy: ImportPolicy
            let stage: ImportStage
            let originals: [StagedOriginal]
            let placeholderAssetID: String?
            let receipt: ImportReceipt?
        }

        init(_ job: ImportJob) {
            id = job.id
            camera = job.camera
            importDate = job.importDate
            revision = job.revision
            pauseReason = job.pauseReason
            captures = job.captures.map {
                .init(id: $0.id, descriptors: $0.selection.descriptors, policy: $0.selection.policy, stage: $0.stage,
                      originals: $0.originals, placeholderAssetID: $0.placeholderAssetID, receipt: $0.receipt)
            }
        }
    }

    init(snapshot: Snapshot) throws {
        id = snapshot.id
        camera = snapshot.camera
        importDate = snapshot.importDate
        revision = snapshot.revision
        pauseReason = snapshot.pauseReason
        let identity = snapshot.camera.redactedIdentity
        captures = snapshot.captures.map { entry in
            .init(selection: .init(captureID: entry.id, camera: identity, descriptors: entry.descriptors, policy: entry.policy),
                  stage: entry.stage, originals: entry.originals, placeholderAssetID: entry.placeholderAssetID,
                  receipt: entry.receipt)
        }
        frozenSelections = captures.map(\.selection)
        try validate()
    }
}

extension ImportSelection {
    func validateForOriginalImport() throws {
        let expected: [WirelessObjectFormat] = policy == .pair ? [.raf, .jpeg] : [.raf]
        guard descriptors.map(\.format) == expected, captureID == .init(describing: descriptors),
              descriptors.allSatisfy({ $0.cameraID == camera.cameraID && $0.byteLength > 0
                  && $0.byteLength <= UInt64(Int64.max) }) else {
            throw OriginalImportError.invalidSelection
        }
        if policy == .pair {
            let raw = descriptors[0]
            let jpeg = descriptors[1]
            let inventory = WirelessStorageInventory(
                storage: [raw.storageID: .complete].merging([jpeg.storageID: .complete]) { current, _ in current },
                rawExposure: .available)
            guard CaptureResolver.resolve(objects: descriptors, inventory: inventory)
                .contains(where: { $0.id == captureID && $0.availability == .pair }) else {
                throw OriginalImportError.invalidSelection
            }
        }
    }
}
