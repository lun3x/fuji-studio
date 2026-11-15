#if DEBUG
import Foundation
import FujiCameraCore

/// Exercises production session ownership, browsing, staging and recovery in UI fixtures.
@MainActor struct WirelessFixture {
    enum Mode: String, CaseIterable {
        case disabled, unpaired = "--fixture-wireless-unpaired", paired = "--fixture-wireless-paired"
        case unverifiedSave = "--fixture-wireless-unverified-save"
        case unidentifiedSave = "--fixture-wireless-unidentified-save"

        static func launchModes(in arguments: [String]) -> [Self] {
            arguments.compactMap { Self(rawValue: $0) }.filter { $0 != .disabled }
        }
    }

    let services: WirelessServices
    let bluetooth: FixtureBluetooth
    let wifi: FixtureWiFi
    let session: FixtureWirelessSession
    let photos: FixtureImportPhotos
    let journalRoot: URL

    init(mode: Mode, root: URL, reader: FixtureLibrary, ownership: some WirelessCameraOwnershipGateway) throws {
        let store = FixtureSavedCameras(selected: mode != .unpaired && mode != .disabled)
        let bluetooth = FixtureBluetooth(store: store)
        let wifi = FixtureWiFi()
        let session = try FixtureWirelessSession(identity: store.identity)
        journalRoot = root.appendingPathComponent("import-journal")
        let journal = try ImportJournal(root: journalRoot)
        let staging = try ImportStagingStore(root: root.appendingPathComponent("import-staging"))
        let photos = FixtureImportPhotos(reader: reader, verifySaves: mode != .unverifiedSave && mode != .unidentifiedSave,
                                        providesPlaceholder: mode != .unidentifiedSave)
        self.bluetooth = bluetooth; self.wifi = wifi; self.session = session; self.photos = photos
        let connection = WirelessConnectionCoordinator(bluetooth: bluetooth, store: store, authorization: { .allowed },
            wifi: wifi, ownership: ownership, sessionFactory: { _, _ in
                await session.begin()
                return session
            })
        services = .init(connection: connection, journal: journal, staging: staging, photoGateway: photos,
                         isEnabled: mode != .disabled, requestPhotosAccess: { await reader.requestAccess() })
    }

    static func inactiveServices(journal: ImportJournal, staging: ImportStagingStore) -> WirelessServices {
        let store = FixtureSavedCameras(selected: false)
        let connection = WirelessConnectionCoordinator(bluetooth: FixtureBluetooth(store: store), store: store,
                                                        authorization: { .denied })
        return .init(connection: connection, journal: journal, staging: staging,
                     photoGateway: FixtureImportPhotos(reader: nil, verifySaves: false),
                     isEnabled: false, requestPhotosAccess: { .denied })
    }
}

actor FixtureSavedCameras: SavedCameraStore {
    nonisolated let camera = SavedCamera(id: .init(), peripheralID: UUID(), model: .xt5, displayName: "Fixture X-T5")
    nonisolated var identity: WirelessIdentity {
        .init(cameraID: camera.id, model: .xt5, firmware: "4.32", protocolPeerKey: .init(bytes: Data([1, 2, 3])))
    }
    private var remembered: SavedCamera?
    private var selection: WirelessCameraID?

    init(selected: Bool) {
        if selected { remembered = camera; selection = camera.id }
    }
    func cameras() -> [SavedCamera] { remembered.map { [$0] } ?? [] }
    func selected() -> WirelessCameraID? { selection }
    func save(_ camera: SavedCamera) { remembered = camera }
    func select(_ id: WirelessCameraID?) { selection = id }
    func restoreSelection(_ previous: WirelessCameraID?, replacing candidate: WirelessCameraID) {
        if selection == candidate { selection = previous }
    }
    func forget(_ id: WirelessCameraID) {
        if selection == id { selection = nil }
        if remembered?.id == id { remembered = nil }
    }
}

actor FixtureBluetooth: BluetoothGateway {
    private let store: FixtureSavedCameras
    private(set) var reconnectPrompts: [Bool] = []

    init(store: FixtureSavedCameras) { self.store = store }
    func discover() -> AsyncThrowingStream<[DiscoveredCamera], Error> {
        .init { stream in
            stream.yield([.init(peripheralID: store.camera.peripheralID, advertisedModelHint: .xt5,
                                displayName: store.camera.displayName)])
        }
    }
    func pair(_ camera: DiscoveredCamera) async throws -> SavedCamera {
        guard camera.peripheralID == store.camera.peripheralID else { throw WirelessFailure.peerMismatch }
        await store.save(store.camera)
        return store.camera
    }
    func reconnect(_ camera: SavedCamera, allowPermissionPrompt: Bool) throws {
        guard camera.id == store.camera.id else { throw WirelessFailure.peerMismatch }
        reconnectPrompts.append(allowPermissionPrompt)
    }
    func identity(for id: WirelessCameraID) throws -> WirelessIdentity {
        guard id == store.camera.id else { throw WirelessFailure.peerMismatch }
        return store.identity
    }
    func activateWiFi(for id: WirelessCameraID) throws -> CameraNetwork {
        _ = try identity(for: id)
        return .init(ssid: "Fixture WiFi", security: .wpaPersonal,
                     credential: .init(cameraID: id, version: UUID()), isHidden: false)
    }
    func events() -> AsyncStream<BluetoothGatewayEvent> { .init { _ in } }
    func disconnect() {}
}

actor FixtureWiFi: WiFiJoinGateway {
    private var joinBarrier: FixtureBarrier?
    private(set) var joinCount = 0

    func holdJoin(_ barrier: FixtureBarrier) { joinBarrier = barrier }
    func join(_ network: CameraNetwork) async throws -> JoinedCameraNetwork {
        joinCount += 1
        if let barrier = joinBarrier {
            joinBarrier = nil
            await barrier.wait()
        }
        return .init(ssid: network.ssid, ownsTemporaryConfiguration: true)
    }
    func verify(_ network: JoinedCameraNetwork) {}
    func leave(_ network: JoinedCameraNetwork) {}
    func drainPendingJoin() {}
}

actor FixtureWirelessSession: WirelessTransferSession {
    let identity: WirelessIdentity
    private let jpeg: Data
    private let raf: Data
    private var sessionID = UUID()
    private var closed = false
    private var enumerations = 0
    private var inventoryBarrier: FixtureBarrier?
    private var inventoryHeld = false
    private var closeBarrier: FixtureBarrier?
    private var downloadFailure: WirelessFailure?
    private(set) var closeCount = 0
    private(set) var thumbnailCount = 0
    private(set) var downloadCount = 0
    private(set) var commandsDuringInventory = 0

    init(identity: WirelessIdentity) throws {
        self.identity = identity
        (jpeg, raf) = try fixtureWirelessOriginals()
    }

    var selections: [ImportSelection] {
        [true, false].enumerated().map { index, pair in
            let formats: [WirelessObjectFormat] = pair ? [.raf, .jpeg] : [.raf]
            let objects = formats.enumerated().map { offset, format in
                WirelessObjectDescriptor(cameraID: identity.cameraID, sessionID: sessionID, storageID: 1,
                    handle: UInt32(index * 2 + offset + 1), directory: "DCIM/100_FUJI",
                    filename: String(format: "DSCF%04d.%@", index + 1, format == .raf ? "RAF" : "JPG"),
                    format: format, byteLength: UInt64((format == .raf ? raf : jpeg).count),
                    captureDate: index == 0 ? "20200102T030405+0000" : "20200101T030405+0000",
                    dimensions: format == .raf ? .init(width: 7728, height: 5152) : .init(width: 6, height: 4),
                    orientation: 1, hasThumbnail: true)
            }
            return .init(captureID: .init(describing: objects), camera: identity, descriptors: objects,
                         policy: pair ? .pair : .rawOnly)
        }
    }
    func begin() { sessionID = UUID(); closed = false; enumerations = 0 }
    func holdBrowserInventory(_ barrier: FixtureBarrier) { inventoryBarrier = barrier }
    func holdClose(_ barrier: FixtureBarrier) { closeBarrier = barrier }
    func failNextDownload(_ failure: WirelessFailure) { downloadFailure = failure }
    func open() throws -> WirelessIdentity {
        guard !closed else { throw WirelessFailure.connectionLost }
        return identity
    }
    func capabilities() -> WirelessCapabilities {
        .init(mode: .xApp, rawExposure: .available, storageIDs: [1], originalSizeVerified: true, evidenceID: "fixture")
    }
    func enumerate() throws -> AsyncThrowingStream<WirelessInventoryBatch, Error> {
        _ = try open()
        if inventoryHeld { commandsDuringInventory += 1; throw WirelessFailure.cameraBusy }
        enumerations += 1
        let batch = WirelessInventoryBatch(objects: selections.flatMap(\.descriptors), storageChanges: [1: .complete], rawExposure: .available)
        let (stream, continuation) = AsyncThrowingStream<WirelessInventoryBatch, Error>.makeStream()
        if enumerations == 2, let barrier = inventoryBarrier {
            inventoryBarrier = nil
            inventoryHeld = true
            Task {
                await barrier.wait()
                inventoryHeld = false
                continuation.yield(batch)
                continuation.finish()
            }
        } else {
            continuation.yield(batch)
            continuation.finish()
        }
        return stream
    }
    func thumbnail(_ object: WirelessObjectDescriptor) throws -> Data {
        thumbnailCount += 1
        _ = try open()
        guard object.sessionID == sessionID else { throw WirelessFailure.objectChanged }
        return jpeg
    }
    func download(_ object: WirelessObjectDescriptor, to sink: @escaping @Sendable (Data) async throws -> Void) async throws {
        downloadCount += 1
        _ = try open()
        if inventoryHeld { commandsDuringInventory += 1; throw WirelessFailure.cameraBusy }
        if let failure = downloadFailure { downloadFailure = nil; throw failure }
        guard selections.flatMap(\.descriptors).contains(object) else { throw WirelessFailure.objectChanged }
        try await sink(object.format == .raf ? raf : jpeg)
    }
    func close() async {
        if let barrier = closeBarrier {
            closeBarrier = nil
            await barrier.wait()
        }
        if !closed { closed = true; closeCount += 1 }
    }
}

actor FixtureImportPhotos: PhotoImportGateway {
    private let reader: FixtureLibrary?
    private let verifySaves: Bool
    private let providesPlaceholder: Bool
    private var createBarrier: FixtureBarrier?
    private var inspectionBarrier: FixtureBarrier?
    private var rejection: PhotoImportFailure?
    private var notifyInsertions = true
    private var hideNextAsset = false
    private var hiddenCaptures: [String: ValidatedCapture] = [:]
    private var assets: [String: ImportedAssetInspection] = [:]
    private(set) var createCount = 0

    init(reader: FixtureLibrary?, verifySaves: Bool, providesPlaceholder: Bool = true) {
        self.reader = reader; self.verifySaves = verifySaves; self.providesPlaceholder = providesPlaceholder
    }
    func holdCreate(_ barrier: FixtureBarrier) { createBarrier = barrier }
    func holdNextInspection(_ barrier: FixtureBarrier) { inspectionBarrier = barrier }
    func rejectNextCreate(_ failure: PhotoImportFailure) { rejection = failure }
    func suppressInsertionNotifications() { notifyInsertions = false }
    func hideNextSaveFromLibrary() { hideNextAsset = true }

    func grantLibraryAccess(to assetID: String) async {
        guard let capture = hiddenCaptures.removeValue(forKey: assetID) else { return }
        assets[assetID] = .found(verifiableAsset(id: assetID, capture: capture))
        await reader?.addWirelessImport(assetID, capture: capture, notify: true)
    }

    func create(_ capture: ValidatedCapture,
                onPlaceholder: @escaping @Sendable (String) throws -> Void) async -> PhotoImportOutcome {
        createCount += 1
        if let failure = rejection {
            rejection = nil
            return .rejected(failure)
        }
        let id = "wireless-\(createCount)"
        if providesPlaceholder {
            do { try onPlaceholder(id) } catch { return .uncertain(assetID: id) }
        }
        if hideNextAsset {
            hideNextAsset = false
            hiddenCaptures[id] = capture
            return .submitted(assetID: id)
        }
        await reader?.addWirelessImport(id, capture: capture, notify: notifyInsertions)
        if let barrier = createBarrier {
            createBarrier = nil
            await barrier.wait()
        }
        assets[id] = verifySaves ? .found(verifiableAsset(id: id, capture: capture)) : .foundUnreadable
        return providesPlaceholder ? .submitted(assetID: id) : .uncertain(assetID: nil)
    }

    private func verifiableAsset(id: String, capture: ValidatedCapture) -> ImportedAssetSnapshot {
        let resources = capture.originals.map { original in
            ImportedResourceFingerprint(role: capture.originals.count == 2 && original.role == .raf ? .alternate : .primary,
                format: original.role, originalFilename: original.originalFilename, byteCount: original.byteCount, sha256: original.sha256)
        }
        return .init(assetID: id, originals: resources)
    }
    func inspect(assetID: String) async -> ImportedAssetInspection {
        let result = assets[assetID] ?? .unavailable
        if let barrier = inspectionBarrier {
            inspectionBarrier = nil
            await barrier.wait()
        }
        return result
    }
    func candidates(for capture: ValidatedCapture) -> [String] { [] }
}
#endif
