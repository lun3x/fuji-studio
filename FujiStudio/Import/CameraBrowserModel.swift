import Foundation
import FujiCameraCore
import Observation
import Synchronization

enum CameraBrowserSelectionError: Error, Equatable {
    case captureChanged
    case ambiguousCapture
    case unavailablePolicy
    case inventoryNotReady
}

@MainActor @Observable
final class CameraBrowserModel {
    private(set) var captures: [CameraCapture] = []
    private(set) var inventory = WirelessStorageInventory()
    private(set) var isLoading = false
    private(set) var failure: WirelessFailure?
    private(set) var requiresFreshSession = false
    private(set) var canSelectOriginals = false
    private(set) var selectedCount = 0
    private(set) var knownByteEstimate: UInt64 = 0
    @ObservationIgnored var onSessionInvalidated: ((WirelessFailure) -> Void)?
    private var receiptStatuses: [WirelessObjectDescriptor: ImportReceiptStatus] = [:]
    var inventorySessionID: UUID? { captures.first?.rowID.sessionID }

    private var selected: [CameraCaptureID: ImportSelection] = [:]
    @ObservationIgnored private var capturesByID: [CameraCaptureID: [CameraCapture]] = [:]
    @ObservationIgnored private var visibleRows: [WirelessObjectDescriptor: CameraCapture] = [:]
    @ObservationIgnored private var camera: WirelessIdentity?
    @ObservationIgnored private var session: (any WirelessTransferSession)?
    @ObservationIgnored private var invalidatedSessions: [UUID: WirelessFailure] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var thumbnailGeneration = UUID()
    @ObservationIgnored private var receiptGeneration = UUID()
    @ObservationIgnored private var thumbnailsSuspended = false
    @ObservationIgnored private var operationTail: Task<Void, Never>?
    @ObservationIgnored private var thumbnailCache = ThumbnailCache()

    /// The connection coordinator owns the borrowed session and its eventual closure.
    func load(session: any WirelessTransferSession) async {
        cancel()
        let generation = generation
        let cancellation = BrowserCancellation()
        self.session = session
        isLoading = true

        await withTaskCancellationHandler {
            do {
                try await readInventory(session: session, generation: generation, cancellation: cancellation)
            } catch {
                guard self.generation == generation else { return }
                if error is CancellationError {
                    cancel()
                } else {
                    isLoading = false
                    let failure = error as? WirelessFailure ?? .connectionLost
                    self.failure = failure
                    requiresFreshSession = true
                    onSessionInvalidated?(failure)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    func select(_ id: CameraCaptureID, policy: ImportPolicy) throws {
        guard !isLoading, failure == nil, let camera else {
            throw CameraBrowserSelectionError.inventoryNotReady
        }
        guard let matches = capturesByID[id], let capture = matches.first else {
            throw CameraBrowserSelectionError.captureChanged
        }
        guard matches.count == 1 else { throw CameraBrowserSelectionError.ambiguousCapture }
        let descriptors = try resources(for: capture, policy: policy)
        guard descriptors.allSatisfy({ inventory.storage[$0.storageID] == .complete }) else {
            throw WirelessFailure.unavailableStorage
        }
        guard canSelectOriginals, descriptors.allSatisfy({ $0.byteLength > 0 && $0.byteLength <= UInt32.max }) else {
            throw WirelessFailure.originalSizeUnavailable
        }
        selected[id] = .init(captureID: id, camera: camera, descriptors: descriptors, policy: policy)
        updateSelectionTotals()
    }

    func deselect(_ id: CameraCaptureID) {
        selected.removeValue(forKey: id)
        updateSelectionTotals()
    }

    func selectedPolicy(for id: CameraCaptureID) -> ImportPolicy? { selected[id]?.policy }

    func importReceiptStatus(for capture: CameraCapture) -> ImportReceiptStatus? {
        receiptStatuses[capture.rowID]
    }

    /// Evidence is scoped to the exact observed session objects. This reads Photos
    /// for receipts only and does not initiate original downloads while browsing.
    func refreshImportReceipts(using recovery: ImportRecovery,
                               originalFingerprints: [WirelessObjectDescriptor: ImportOriginalFingerprint]) async throws {
        clearReceiptStatuses()
        guard !originalFingerprints.isEmpty, !isLoading, failure == nil else { return }
        let generation = receiptGeneration
        let jobs = try await recovery.journal.loadJobs()
        var statuses: [WirelessObjectDescriptor: ImportReceiptStatus] = [:]
        for capture in captures {
            try Task.checkCancellation()
            guard generation == receiptGeneration else { return }
            let originals = capture.objects.compactMap { object in
                originalFingerprints[object].flatMap { $0.describes(object) ? $0 : nil }
            }
            guard capture.raw != nil, originals.count == capture.objects.count else { continue }
            statuses[capture.rowID] = await recovery.lookup(originals, jobs: jobs).status
        }
        try Task.checkCancellation()
        guard generation == receiptGeneration else { return }
        receiptStatuses = statuses
    }

    private func clearReceiptStatuses() {
        receiptGeneration = UUID()
        receiptStatuses.removeAll()
    }

    func selectionForImport() throws -> [ImportSelection] {
        guard !selected.isEmpty else { return [] }
        guard !isLoading, failure == nil, canSelectOriginals, let camera else {
            throw CameraBrowserSelectionError.inventoryNotReady
        }
        let ordered = try captures.compactMap { capture -> ImportSelection? in
            guard let selection = selected[capture.id] else { return nil }
            guard capturesByID[capture.id]?.count == 1, camera == selection.camera,
                  try resources(for: capture, policy: selection.policy) == selection.descriptors else {
                throw CameraBrowserSelectionError.captureChanged
            }
            return selection
        }
        guard ordered.count == selected.count else { throw CameraBrowserSelectionError.captureChanged }
        return ordered
    }

    /// Loads one preview for a visible row. Callers can cancel their own request, such
    /// as when a row leaves the viewport. An active PTP transaction drains first.
    func thumbnail(for capture: CameraCapture) async -> Data? {
        guard let session, let object = capture.thumbnailObject, !thumbnailsSuspended, failure == nil,
              visibleRows[capture.rowID]?.thumbnailObject == object, !Task.isCancelled else { return nil }
        if let data = thumbnailCache.value(for: object) { return data }

        let generation = generation
        let thumbnailGeneration = thumbnailGeneration
        let cancellation = BrowserCancellation()
        let work = enqueue { [weak self] () async throws -> Data? in
            guard let self,
                  self.acceptsThumbnail(capture, generation, thumbnailGeneration, cancellation) else { return nil }
            if let data = self.thumbnailCache.value(for: object) { return data }
            let data: Data
            do {
                data = try await session.thumbnail(object)
            } catch {
                if let failure = Self.invalidatingPreviewFailure(error) {
                    self.invalidateInventory(failure, sessionID: object.sessionID, generation: generation)
                }
                return nil
            }
            guard self.acceptsThumbnail(capture, generation, thumbnailGeneration, cancellation),
                  !data.isEmpty else { return nil }
            self.thumbnailCache.insert(data, for: object)
            return data
        }
        return await withTaskCancellationHandler {
            let data = try? await work.value
            guard acceptsThumbnail(capture, generation, thumbnailGeneration, cancellation) else { return nil }
            return data
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Let an importer take the shared socket after already-started preview work drains.
    /// Freeze the selection after this drains, and resume only after transfer releases it.
    func suspendThumbnails() async {
        thumbnailsSuspended = true
        thumbnailGeneration = UUID()
        await operationTail?.value
    }

    func resumeThumbnails() { thumbnailsSuspended = false }

    func cancel() {
        generation = UUID()
        thumbnailGeneration = UUID()
        thumbnailsSuspended = false
        isLoading = false
        failure = nil
        requiresFreshSession = false
        canSelectOriginals = false
        inventory = .init()
        camera = nil
        session = nil
        clearReceiptStatuses()
        publish([])
        selected.removeAll()
        updateSelectionTotals()
        thumbnailCache = .init()
    }

    private struct Admission: Sendable {
        let camera: WirelessIdentity
        let stream: AsyncThrowingStream<WirelessInventoryBatch, Error>
        let capabilities: WirelessCapabilities
    }

    private func readInventory(
        session: any WirelessTransferSession, generation: UUID, cancellation: BrowserCancellation
    ) async throws {
        let admission = try await enqueue {
            try self.checkCurrent(generation, cancellation)
            let camera = try await session.open()
            try self.checkCurrent(generation, cancellation)
            let stream = try await session.enumerate()
            try self.checkCurrent(generation, cancellation)
            let capabilities = try await session.capabilities()
            return Admission(camera: camera, stream: stream, capabilities: capabilities)
        }.value
        try checkCurrent(generation, cancellation)
        camera = admission.camera
        inventory = .init(storage: Dictionary(admission.capabilities.storageIDs.map { ($0, .pending) },
                                              uniquingKeysWith: { state, _ in state }),
                          rawExposure: admission.capabilities.rawExposure)

        let cursor = InventoryCursor(admission.stream)
        var objectsByCard: [UInt32: [UInt32: WirelessObjectDescriptor]] = [:]
        var objectSessionID: UUID?
        var checkingRows: [CameraCapture] = []
        let clock = ContinuousClock()
        var nextPublication = clock.now
        while true {
            let batch = try await enqueue {
                try self.checkCurrent(generation, cancellation)
                return try await cursor.next()
            }.value
            try checkCurrent(generation, cancellation)
            guard let batch else { break }
            inventory.apply(batch)
            for object in batch.objects {
                guard object.cameraID == admission.camera.cameraID,
                      objectSessionID == nil || objectSessionID == object.sessionID else {
                    throw WirelessFailure.peerMismatch
                }
                if let failure = invalidatedSessions[object.sessionID] {
                    invalidateInventory(failure, sessionID: object.sessionID, generation: generation)
                    return
                }
                objectSessionID = object.sessionID
                if let previous = objectsByCard[object.storageID]?[object.handle] {
                    guard previous == object else { throw WirelessFailure.objectChanged }
                    continue
                }
                guard (objectsByCard[object.storageID]?.count ?? 0) < WirelessPTPTransport.maximumObjectsPerStorage else {
                    throw WirelessFailure.malformedData
                }
                objectsByCard[object.storageID, default: [:]][object.handle] = object
                checkingRows.append(CaptureResolver.checking(object))
            }
            if checkingRows.count > captures.count, clock.now >= nextPublication {
                publish(checkingRows.sorted(by: CameraCapture.newestFirst))
                // Coalesce larger galleries so each 16-object PTP batch doesn't re-sort every row.
                let interval = max(250, checkingRows.count / 40)
                nextPublication = clock.now + .milliseconds(interval)
            }
        }

        let capabilities = try await enqueue {
            try self.checkCurrent(generation, cancellation)
            return try await session.capabilities()
        }.value
        try checkCurrent(generation, cancellation)
        let objects = objectsByCard.values.flatMap { $0.values }
        let resolutionInventory = inventory
        let resolved = await Task.detached {
            CaptureResolver.resolve(objects: objects, inventory: resolutionInventory)
        }.value
        try checkCurrent(generation, cancellation)
        publish(resolved)
        canSelectOriginals = capabilities.originalSizeVerified
        isLoading = false
    }

    private func publish(_ captures: [CameraCapture]) {
        self.captures = captures
        capturesByID = Dictionary(grouping: captures, by: \.id)
        visibleRows = Dictionary(captures.map { ($0.rowID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func checkCurrent(_ generation: UUID, _ cancellation: BrowserCancellation) throws {
        guard self.generation == generation, !cancellation.isCancelled else { throw CancellationError() }
    }

    private func invalidateInventory(_ failure: WirelessFailure, sessionID: UUID, generation: UUID) {
        // Camera-hosted enumeration replays the same session's cached descriptors.
        invalidatedSessions[sessionID] = failure
        guard self.generation == generation else { return }
        self.generation = UUID()
        thumbnailGeneration = UUID()
        isLoading = false
        canSelectOriginals = false
        requiresFreshSession = true
        self.failure = failure
        clearReceiptStatuses()
        thumbnailCache = .init()
        onSessionInvalidated?(failure)
    }

    private static func invalidatingPreviewFailure(_ error: any Error) -> WirelessFailure? {
        switch error {
        case PTPError.responseCode(0x2009): return .objectChanged  // InvalidObjectHandle
        case PTPError.responseCode(0x2008), PTPError.responseCode(0x2013):
            return .unavailableStorage  // InvalidStorageID, StoreNotAvailable
        case PTPError.responseCode(0x2003): return .connectionLost  // SessionNotOpen
        case PTPError.timeout: return .timeout(.transactionInactivity)
        case PTPError.responseCode, PTPError.busy, WirelessFailure.unsupportedProtocol, WirelessFailure.cameraBusy:
            // A correlated command rejection can leave the session synchronized.
            return nil
        case let failure as WirelessFailure: return failure
        default: return .connectionLost
        }
    }

    private func acceptsThumbnail(
        _ capture: CameraCapture, _ generation: UUID, _ thumbnailGeneration: UUID, _ cancellation: BrowserCancellation
    ) -> Bool {
        self.generation == generation && self.thumbnailGeneration == thumbnailGeneration
            && !thumbnailsSuspended && !cancellation.isCancelled
            && visibleRows[capture.rowID]?.thumbnailObject == capture.thumbnailObject
    }

    private func resources(for capture: CameraCapture, policy: ImportPolicy) throws -> [WirelessObjectDescriptor] {
        switch policy {
        case .pair:
            guard capture.availability == .pair, let raw = capture.raw, let jpeg = capture.jpeg else {
                throw CameraBrowserSelectionError.unavailablePolicy
            }
            return [raw, jpeg]
        case .rawOnly:
            guard capture.availability == .rawOnly || capture.availability == .ambiguous,
                  let raw = capture.raw else { throw CameraBrowserSelectionError.unavailablePolicy }
            return [raw]
        }
    }

    private func updateSelectionTotals() {
        selectedCount = selected.count
        knownByteEstimate = selected.values.reduce(0) { total, selection in
            selection.descriptors.reduce(total) { $0 + $1.byteLength }
        }
    }

    /// Serializes logical operations across actor suspensions. Canceling a waiter must
    /// not cancel the active PTP command, which would close the coordinator's socket.
    private func enqueue<T: Sendable>(
        _ operation: @escaping @MainActor () async throws -> T
    ) -> Task<T, Error> {
        let previous = operationTail
        let work = Task {
            await previous?.value
            return try await operation()
        }
        operationTail = Task { _ = await work.result }
        return work
    }

    @MainActor private final class InventoryCursor {
        private var iterator: AsyncThrowingStream<WirelessInventoryBatch, Error>.Iterator

        init(_ stream: AsyncThrowingStream<WirelessInventoryBatch, Error>) {
            iterator = stream.makeAsyncIterator()
        }

        func next() async throws -> WirelessInventoryBatch? {
            var iterator = self.iterator
            let batch = try await iterator.next(isolation: #isolation)
            self.iterator = iterator
            return batch
        }
    }
}

private final class BrowserCancellation: Sendable {
    private let cancelled = Mutex(false)
    var isCancelled: Bool { cancelled.withLock { $0 } }
    func cancel() { cancelled.withLock { $0 = true } }
}

private struct ThumbnailCache {
    private static let limit = 32 * 1024 * 1024
    // Exact descriptor equality includes session, route and the original's fingerprint.
    private var entries: [WirelessObjectDescriptor: Data] = [:]
    private var leastRecentFirst: [WirelessObjectDescriptor] = []
    private var bytes = 0

    mutating func value(for key: WirelessObjectDescriptor) -> Data? {
        guard let data = entries[key] else { return nil }
        leastRecentFirst.removeAll { $0 == key }
        leastRecentFirst.append(key)
        return data
    }

    mutating func insert(_ data: Data, for key: WirelessObjectDescriptor) {
        guard data.count <= Self.limit else { return }
        while bytes + data.count > Self.limit, !leastRecentFirst.isEmpty {
            let oldest = leastRecentFirst.removeFirst()
            bytes -= entries.removeValue(forKey: oldest)?.count ?? 0
        }
        bytes += data.count
        entries[key] = data
        leastRecentFirst.append(key)
    }
}
