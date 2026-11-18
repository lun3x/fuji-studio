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
    private(set) var dayGroups: [CameraCaptureDayGroup] = []
    private(set) var originalSizeFailure: WirelessFailure?
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

    private(set) var workspace = WorkspaceState(access: .full)
    private(set) var traySources: [PhotoSource] = []
    @ObservationIgnored private var trayCaptures: [SourceID: CameraCapture] = [:]
    @ObservationIgnored private var rawOrder: [SourceID] = []

    private let originalCache: CameraOriginalCache
    private var explicitRAW: SourceID?
    @ObservationIgnored private var inventoryWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    @ObservationIgnored private var viewedFiles: [WirelessObjectDescriptor: ViewerFile] = [:]

    init(originalCache: CameraOriginalCache = CameraOriginalCache(root: ImportDisk.root("camera-originals"))) {
        self.originalCache = originalCache
    }

    struct ViewerRequest: Equatable {
        let id: SourceID
        let thumbnail: WirelessObjectDescriptor?
        let original: WirelessObjectDescriptor?
    }

    var viewerRequest: ViewerRequest? {
        guard let id = workspace.viewedSourceID, let capture = trayCaptures[id] else { return nil }
        return .init(id: id, thumbnail: capture.thumbnailObject, original: explicitRAW == id ? capture.raw : capture.jpeg)
    }

    func apply(_ action: WorkspaceAction) {
        _ = workspace.reduce(action)
        switch action {
        case .sourceTapped: explicitRAW = nil
        case .versionSelected(let version): explicitRAW = version == .raw ? workspace.viewedSourceID : nil
        default: break
        }
    }

    func alreadyViewed(_ object: WirelessObjectDescriptor) -> ViewerFile? { viewedFiles[object] }
    func capture(for id: SourceID) -> CameraCapture? { trayCaptures[id] }

    var canSaveWorkspaceSelection: Bool {
        guard canSelectOriginals, !thumbnailsSuspended, failure == nil else { return false }
        let ids = workspace.effectiveSourceIDs
        if !isFindingMates(for: ids) { return (try? workspaceSelections(for: ids).isEmpty) == false }
        return ids.contains { id in
            guard let capture = trayCaptures[id] else { return false }
            return receiptStatuses[capture.rowID] != .verified
        }
    }

    func waitForInventoryChange() async {
        let id = UUID()
        let (changes, continuation) = AsyncStream<Void>.makeStream()
        inventoryWaiters[id] = continuation
        defer { inventoryWaiters[id] = nil }
        for await _ in changes {}
    }

    private func signalInventoryChange() {
        for waiter in inventoryWaiters.values { waiter.finish() }
        inventoryWaiters.removeAll()
    }

    func isFindingMates(for ids: [SourceID]) -> Bool {
        isLoading && ids.contains { trayCaptures[$0]?.availability == .checking }
    }

    func workspaceSelections(for ids: [SourceID]) throws -> [ImportSelection] {
        try ids.compactMap { id in
            guard let capture = trayCaptures[id] else { throw CameraBrowserSelectionError.captureChanged }
            guard receiptStatuses[capture.rowID] != .verified else { return nil }
            return try proposedSelection(for: capture.id, policy: capture.jpeg == nil ? .rawOnly : .pair, allowMatchedPair: true)
        }
    }

    private var selected: [CameraCaptureID: ImportSelection] = [:]
    @ObservationIgnored private var capturesByID: [CameraCaptureID: [CameraCapture]] = [:]
    @ObservationIgnored private var visibleRows: [WirelessObjectDescriptor: CameraCapture] = [:]
    @ObservationIgnored private var camera: WirelessIdentity?
    @ObservationIgnored private var session: (any WirelessTransferSession)?
    @ObservationIgnored private var invalidatedSessions: [UUID: WirelessFailure] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var thumbnailGeneration = UUID()
    @ObservationIgnored private var receiptGeneration = UUID()
    private(set) var thumbnailsSuspended = false
    @ObservationIgnored private var operationTail: Task<Void, Never>?
    @ObservationIgnored private var thumbnailCache = ThumbnailCache()

    /// The connection coordinator owns the borrowed session and its eventual closure.
    func load(session: any WirelessTransferSession) async {
        cancel()
        let generation = generation
        let cancellation = BrowserCancellation()
        self.session = session
        isLoading = true
        defer { signalInventoryChange() }

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
        selected[id] = try proposedSelection(for: id, policy: policy)
        updateSelectionTotals()
    }

    func permitsSelection(for id: CameraCaptureID, policy: ImportPolicy) -> Bool {
        (try? proposedSelection(for: id, policy: policy)) != nil
    }

    private func proposedSelection(for id: CameraCaptureID, policy: ImportPolicy, allowMatchedPair: Bool = false) throws -> ImportSelection {
        let matchedPair = allowMatchedPair && policy == .pair
        guard (!isLoading || matchedPair), failure == nil, let camera else {
            throw CameraBrowserSelectionError.inventoryNotReady
        }
        guard let matches = capturesByID[id], let capture = matches.first else {
            throw CameraBrowserSelectionError.captureChanged
        }
        guard matches.count == 1 else { throw CameraBrowserSelectionError.ambiguousCapture }
        let descriptors = try resources(for: capture, policy: policy)
        guard matchedPair || descriptors.allSatisfy({ inventory.storage[$0.storageID] == .complete }) else {
            throw WirelessFailure.unavailableStorage
        }
        if let originalSizeFailure { throw originalSizeFailure }
        guard canSelectOriginals, descriptors.allSatisfy({ $0.byteLength > 0 && $0.byteLength <= UInt32.max }) else {
            throw WirelessFailure.originalSizeUnavailable
        }
        return .init(captureID: id, camera: camera, descriptors: descriptors, policy: policy)
    }

    func deselect(_ id: CameraCaptureID) {
        deselect([id])
    }

    func deselectVerifiedCaptures() {
        guard !selected.isEmpty, !receiptStatuses.isEmpty else { return }
        deselect(captures.compactMap { capture in
            receiptStatuses[capture.rowID] == .verified && selected[capture.id] != nil ? capture.id : nil
        })
    }

    private func deselect(_ ids: [CameraCaptureID]) {
        guard !ids.isEmpty else { return }
        for id in ids { selected.removeValue(forKey: id) }
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
        guard !originalFingerprints.isEmpty, failure == nil else { return }
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

    func viewerFile(for object: WirelessObjectDescriptor) async throws -> ViewerFile {
        if let file = alreadyViewed(object) { return file }
        guard let session, !thumbnailsSuspended else { throw WirelessFailure.connectionLost }
        let generation = generation
        let cancellation = BrowserCancellation()
        // An already-started command must drain before another view or import uses the socket.
        let work = enqueue {
            try self.checkCurrent(generation, cancellation)
            guard !self.thumbnailsSuspended, self.trayCaptures.values.contains(where: { $0.objects.contains(object) })
            else { throw CancellationError() }
            if let file = self.alreadyViewed(object) { return file }
            let file = try await CameraViewerOriginal.load(object, cache: self.originalCache, session: session)
            guard self.generation == generation else { throw CancellationError() }
            self.viewedFiles[object] = file
            try self.checkCurrent(generation, cancellation)
            return file
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { cancellation.cancel() }
    }

    /// Let an importer take the shared socket after already-started preview work drains.
    /// Freeze the selection after this drains, and resume only after transfer releases it.
    func suspendThumbnails() async {
        thumbnailsSuspended = true
        thumbnailGeneration = UUID()
        await operationTail?.value
    }

    func resumeThumbnails() {
        thumbnailsSuspended = false
        signalInventoryChange()
    }

    func cancel() {
        generation = UUID()
        thumbnailGeneration = UUID()
        thumbnailsSuspended = false
        isLoading = false
        failure = nil
        requiresFreshSession = false
        canSelectOriginals = false
        originalSizeFailure = nil
        inventory = .init()
        camera = nil
        session = nil
        clearReceiptStatuses()
        rawOrder = []
        explicitRAW = nil
        viewedFiles.removeAll()
        workspace = WorkspaceState(access: .full)
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
        var provisional = ProgressiveCameraCaptures()
        var count = 0
        let clock = ContinuousClock()
        var nextPublication = clock.now
        var capabilities = admission.capabilities
        while true {
            // Finish the in-flight batch before lending the socket to a selected import.
            while thumbnailsSuspended {
                try checkCurrent(generation, cancellation)
                await waitForInventoryChange()
            }
            let next = try await enqueue {
                try self.checkCurrent(generation, cancellation)
                let batch = try await cursor.next()
                return (batch, try await session.capabilities())
            }.value
            try checkCurrent(generation, cancellation)
            capabilities = next.1
            canSelectOriginals = capabilities.originalSizeVerified
            originalSizeFailure = capabilities.originalSizeFailure
            guard let batch = next.0 else { break }
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
                provisional.insert(object)
                count += 1
                if object.format == .raf { rawOrder.append(object.trayID) }
            }
            if !batch.objects.isEmpty, clock.now >= nextPublication {
                publish(provisional.rows(inventory: inventory))
                // Coalesce updates while replaying already-cached batches.
                let interval = max(250, count / 40)
                nextPublication = clock.now + .milliseconds(interval)
            }
        }

        try checkCurrent(generation, cancellation)
        let objects = objectsByCard.values.flatMap { $0.values }
        let resolutionInventory = inventory
        let resolved = await Task.detached {
            CaptureResolver.resolve(objects: objects, inventory: resolutionInventory)
        }.value
        try checkCurrent(generation, cancellation)
        publish(resolved)
        canSelectOriginals = capabilities.originalSizeVerified
        originalSizeFailure = capabilities.originalSizeFailure
        isLoading = false
    }

    private func publish(_ captures: [CameraCapture]) {
        defer { signalInventoryChange() }
        self.captures = captures
        trayCaptures = Dictionary(uniqueKeysWithValues: captures.compactMap { capture in
            capture.raw.map { ($0.trayID, capture) }
        })
        traySources = rawOrder.compactMap { trayCaptures[$0]?.photoSource }
        _ = workspace.reduce(.libraryUpdated(sources: traySources, access: .full))
        if let explicitRAW, explicitRAW == workspace.viewedSourceID, workspace.displayedVersion != .raw {
            _ = workspace.reduce(.versionSelected(.raw))
        }
        let groups = Dictionary(grouping: captures) { $0.timestamp?.calendarDay }
        dayGroups = groups.map { CameraCaptureDayGroup(day: $0.key, captures: $0.value) }
            .sorted { ($0.day ?? "") > ($1.day ?? "") }
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
        signalInventoryChange()
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

/// Only objects with the same filename stem can become mates. Re-evaluate that
/// bucket when either card adds evidence, keeping previously resolved rows.
private struct ProgressiveCameraCaptures {
    private var buckets: [String: [WirelessObjectDescriptor]] = [:]
    private var changed: Set<String> = []
    private var resolved: [String: [CameraCapture]] = [:]

    mutating func insert(_ object: WirelessObjectDescriptor) {
        let key = CameraCaptureEvidence.stem(object) ?? object.filename
        buckets[key, default: []].append(object)
        changed.insert(key)
    }

    mutating func rows(inventory: WirelessStorageInventory) -> [CameraCapture] {
        for key in changed {
            resolved[key] = CaptureResolver.resolve(objects: buckets[key] ?? [], inventory: inventory, provisional: true)
        }
        changed.removeAll(keepingCapacity: true)
        return resolved.values.flatMap { $0 }.sorted(by: CameraCapture.newestFirst)
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
