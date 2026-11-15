import Foundation
import FujiCameraCore

struct ImportActions: OptionSet, Equatable, Sendable {
    let rawValue: UInt16

    static let pause = Self(rawValue: 1 << 0)
    static let resume = Self(rawValue: 1 << 1)
    static let retryCapture = Self(rawValue: 1 << 2)
    static let skipCapture = Self(rawValue: 1 << 3)
    static let cancelRemaining = Self(rawValue: 1 << 4)
    static let discardRemaining = Self(rawValue: 1 << 5)
    static let managePhotos = Self(rawValue: 1 << 6)
}

/// Matches only the observed routes in this exact run and wireless session.
struct ImportRouteEvidence: Equatable, Sendable {
    let runID: UUID
    let sessionID: UUID
    let fingerprints: [WirelessObjectDescriptor: ImportOriginalFingerprint]
}

struct ImportEvent: Equatable, Sendable {
    struct JobContext: Equatable, Sendable {
        let cameraModel: WirelessCameraModel
        let cameraDisplayName: String?
        let startedAt: Date
        let firstFilename: String?
    }

    struct Component: Equatable, Sendable {
        let role: ImportOriginalRole
        let receivedBytes: UInt64
        let expectedBytes: UInt64
    }

    let sequence: UInt64
    let jobID: UUID?
    /// One admission attempt, including its final event. Recovered snapshots have no run.
    let runID: UUID?
    let cameraID: WirelessCameraID?
    let jobContext: JobContext?
    let captureID: CameraCaptureID?
    let captureIndex: Int?
    let captureCount: Int
    let stage: ImportStage?
    let component: Component?
    let isVerifyingPhotos: Bool
    let isRunning: Bool
    let pauseReason: ImportPauseReason?
    let actions: ImportActions
    /// The coordinator has no borrowed session for further camera work. A complete
    /// ready-to-save capture may still be retried locally.
    let needsSession: Bool
    let invalidatedSession: Bool
    let wirelessFailure: WirelessFailure?
    let receipts: [ImportReceipt]
    let routeEvidence: ImportRouteEvidence?
    let retainedBytes: UInt64
    let recoveryRequired: Bool
}

enum CameraImportError: Error, Equatable, Sendable {
    case busy
    case missingJob
    case actionUnavailable
    case sessionRequired
    case freshSelectionRequired
    case unresolvedSave(retainedBytes: UInt64)
}
