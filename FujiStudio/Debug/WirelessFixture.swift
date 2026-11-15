#if DEBUG
import Foundation
import FujiCameraCore

/// Exercises production session ownership, browsing, staging and recovery in UI fixtures.
@MainActor struct WirelessFixture {
    enum Mode: String, CaseIterable {
        case disabled, unpaired = "--fixture-wireless-unpaired", paired = "--fixture-wireless-paired"
        case unverifiedSave = "--fixture-wireless-unverified-save"
        case unidentifiedSave = "--fixture-wireless-unidentified-save"
        case xe3Unpaired = "--fixture-wireless-xe3-unpaired"
        case twoSaved = "--fixture-wireless-two-saved"
        case reconnecting = "--fixture-wireless-reconnecting"
        case retryBluetooth = "--fixture-wireless-retry-bluetooth"
        case firmwareUpdate = "--fixture-wireless-firmware-update"
        case firmwareUnverified = "--fixture-wireless-firmware-unverified"
        case joinDenied = "--fixture-wireless-join-denied"
        case localNetworkDenied = "--fixture-wireless-local-network-denied"
        case formats = "--fixture-wireless-formats"
        case rawUnavailable = "--fixture-wireless-raw-unavailable"
        case slowImport = "--fixture-wireless-slow-import"
        case recoverable = "--fixture-wireless-recoverable"
        case retryable = "--fixture-wireless-retryable"
        case journalIssue = "--fixture-wireless-journal-issue"
        case autoSave = "--fixture-wireless-auto-save"
        case autoSaveOwnershipFailure = "--fixture-wireless-auto-save-ownership-failure"
        case autoSaveInventoryFailure = "--fixture-wireless-auto-save-inventory-failure"
        case autoSaveCloseFailure = "--fixture-wireless-auto-save-close-failure"
        case recoveryJobs = "--fixture-wireless-recovery-jobs"

        var hasAutoSave: Bool {
            self == .autoSave || self == .autoSaveOwnershipFailure || self == .autoSaveInventoryFailure
        }

        var cameraModel: WirelessCameraModel {
            self == .xe3Unpaired || self == .rawUnavailable || self == .autoSaveCloseFailure || hasAutoSave ? .xe3 : .xt5
        }

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
    private let savedCameras: FixtureSavedCameras

    init(mode: Mode, root: URL, reader: FixtureLibrary, ownership: some WirelessCameraOwnershipGateway) throws {
        let persistenceSuite = ProcessInfo.processInfo.environment["FUJI_STUDIO_SETTINGS_SUITE"]
        let autoSaveCameraID = UUID(uuid: (0xFE, 0xE3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
        let cameraID = mode == .autoSave ? WirelessCameraID(rawValue: autoSaveCameraID) : WirelessCameraID()
        let store = FixtureSavedCameras(selected: mode != .unpaired && mode != .xe3Unpaired && mode != .disabled,
                                        model: mode.cameraModel, cameraID: cameraID, dual: mode == .twoSaved || mode == .recoveryJobs)
        savedCameras = store
        let bluetooth = FixtureBluetooth(store: store, mode: mode)
        let wifi = FixtureWiFi(joinFailure: mode == .joinDenied ? .permissionDenied(.wifiJoin) : nil,
                              verifyFailure: mode == .localNetworkDenied ? .permissionDenied(.localNetwork) : nil)
        let identity = store.identity
        let transferFirmware = switch mode {
        case .firmwareUpdate: "4.31"
        case .firmwareUnverified: "4.33"
        default: identity.firmware
        }
        let session = try FixtureWirelessSession(identity: .init(cameraID: identity.cameraID, model: identity.model,
            firmware: transferFirmware, protocolPeerKey: identity.protocolPeerKey), scenario: mode)
        let autoSave: FixtureAutoSave? = if mode.hasAutoSave {
            FixtureAutoSave(session: try FixtureWirelessSession(identity: identity, scenario: mode, transport: .autoSave),
                            persistenceSuite: persistenceSuite)
        } else { nil }
        journalRoot = root.appendingPathComponent("import-journal")
        let journal = try ImportJournal(root: journalRoot)
        if mode == .journalIssue {
            try Data("unreadable".utf8).write(to: journalRoot.appendingPathComponent("\(UUID().uuidString).json"))
        }
        let staging = try ImportStagingStore(root: root.appendingPathComponent("import-staging"))
        let photos = FixtureImportPhotos(reader: reader, verifySaves: mode != .unverifiedSave && mode != .unidentifiedSave,
            providesPlaceholder: mode != .unidentifiedSave, rejection: mode == .retryable ? .storage : nil)
        self.bluetooth = bluetooth; self.wifi = wifi; self.session = session; self.photos = photos
        let connection = WirelessConnectionCoordinator(bluetooth: bluetooth, store: store, authorization: { .allowed },
            wifi: wifi, ownership: FixtureWirelessOwnership(base: ownership, refuse: mode == .autoSaveOwnershipFailure), sessionFactory: { peer, _ in
                if peer.cameraID == identity.cameraID {
                    await session.begin()
                    return session
                }
                return try FixtureWirelessSession(identity: peer, scenario: mode)
            }, autoSave: autoSave)
        services = .init(connection: connection, journal: journal, staging: staging, photoGateway: photos,
                         isEnabled: mode != .disabled, requestPhotosAccess: { await reader.requestAccess() })
    }

    func seedRecoveryJobs() async throws {
        guard let alternate = savedCameras.alternate else { return }
        let alternateSession = try FixtureWirelessSession(identity: savedCameras.identity(for: alternate), transport: .autoSave)
        let journal = try ImportJournal(root: journalRoot)
        let staging = try ImportStagingStore(root: journalRoot.deletingLastPathComponent().appendingPathComponent("import-staging"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for (transfer, mode, name) in [
            (session, WirelessMode.xApp, savedCameras.camera.displayName as String?),
            (session, .xApp, savedCameras.camera.displayName),
            (alternateSession, .autoSave, nil)
        ] {
            let selection = await transfer.selections[0]
            var job = try ImportJob(selections: [selection], importDate: date, mode: mode, cameraDisplayName: name)
            let original = try await staging.write(object: selection.descriptors[0], session: transfer)
            job.captures[0].originals = [original]
            job.captures[0].stage = .downloading
            job.pauseReason = .interrupted
            try await journal.save(job)
        }
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

private struct FixtureWirelessOwnership: WirelessCameraOwnershipGateway {
    let base: any WirelessCameraOwnershipGateway
    let refuse: Bool

    func acquireWireless() async throws -> CameraUseLease {
        if refuse { throw WirelessFailure.usbCloseUnconfirmed }
        return try await base.acquireWireless()
    }

    func releaseWireless(_ lease: CameraUseLease) async {
        await base.releaseWireless(lease)
    }
}

actor FixtureSavedCameras: SavedCameraStore {
    nonisolated let camera: SavedCamera
    nonisolated let alternate: SavedCamera?
    nonisolated var identity: WirelessIdentity {
        identity(for: camera)
    }
    private var remembered: [SavedCamera]
    private var selection: WirelessCameraID?

    init(selected: Bool, model: WirelessCameraModel = .xt5, cameraID: WirelessCameraID = .init(), dual: Bool = false) {
        camera = SavedCamera(id: cameraID, peripheralID: UUID(), model: model, displayName: "Fixture \(model.rawValue)")
        alternate = dual ? SavedCamera(id: .init(), peripheralID: UUID(), model: .xe3, displayName: "Fixture X-E3") : nil
        remembered = selected ? [camera] : []
        if selected { selection = camera.id }
        if let alternate { remembered.append(alternate) }
    }

    nonisolated var discoverable: [SavedCamera] { [camera] + (alternate.map { [$0] } ?? []) }

    nonisolated func identity(for camera: SavedCamera) -> WirelessIdentity {
        .init(cameraID: camera.id, model: camera.model, firmware: camera.model == .xt5 ? "4.32" : "1.32",
              protocolPeerKey: .init(bytes: Data(camera.id.rawValue.uuidString.utf8)))
    }

    func cameras() -> [SavedCamera] { remembered }
    func selected() -> WirelessCameraID? { selection }
    func save(_ camera: SavedCamera) {
        if let index = remembered.firstIndex(where: { $0.id == camera.id }) {
            remembered[index] = camera
        } else {
            remembered.append(camera)
        }
    }
    func select(_ id: WirelessCameraID?) { selection = id }
    func restoreSelection(_ previous: WirelessCameraID?, replacing candidate: WirelessCameraID) {
        if selection == candidate { selection = previous }
    }
    func forget(_ id: WirelessCameraID) {
        if selection == id { selection = nil }
        remembered.removeAll { $0.id == id }
    }
}

actor FixtureBluetooth: BluetoothGateway {
    private let store: FixtureSavedCameras
    private let mode: WirelessFixture.Mode
    private(set) var reconnectPrompts: [Bool] = []

    init(store: FixtureSavedCameras, mode: WirelessFixture.Mode = .paired) {
        self.store = store
        self.mode = mode
    }
    func discover() -> AsyncThrowingStream<[DiscoveredCamera], Error> {
        .init { stream in
            stream.yield(store.discoverable.map {
                .init(peripheralID: $0.peripheralID, advertisedModelHint: $0.model, displayName: $0.displayName)
            })
        }
    }
    func pair(_ camera: DiscoveredCamera) async throws -> SavedCamera {
        guard let match = store.discoverable.first(where: { $0.peripheralID == camera.peripheralID }) else {
            throw WirelessFailure.peerMismatch
        }
        await store.save(match)
        return match
    }
    func reconnect(_ camera: SavedCamera, allowPermissionPrompt: Bool) async throws {
        guard store.discoverable.contains(where: { $0.id == camera.id }) else { throw WirelessFailure.peerMismatch }
        reconnectPrompts.append(allowPermissionPrompt)
        if mode == .retryBluetooth && !allowPermissionPrompt { throw WirelessFailure.authentication }
        if mode == .reconnecting { try await Task.sleep(for: .seconds(12)) }
    }
    func identity(for id: WirelessCameraID) throws -> WirelessIdentity {
        guard let camera = store.discoverable.first(where: { $0.id == id }) else { throw WirelessFailure.peerMismatch }
        return store.identity(for: camera)
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
    private let joinFailure: WirelessFailure?
    private let verifyFailure: WirelessFailure?
    private var joinBarrier: FixtureBarrier?
    private(set) var joinCount = 0

    init(joinFailure: WirelessFailure? = nil, verifyFailure: WirelessFailure? = nil) {
        self.joinFailure = joinFailure
        self.verifyFailure = verifyFailure
    }

    func holdJoin(_ barrier: FixtureBarrier) { joinBarrier = barrier }
    func join(_ network: CameraNetwork) async throws -> JoinedCameraNetwork {
        joinCount += 1
        if let barrier = joinBarrier {
            joinBarrier = nil
            await barrier.wait()
        }
        if let joinFailure { throw joinFailure }
        return .init(ssid: network.ssid, ownsTemporaryConfiguration: true)
    }
    func verify(_ network: JoinedCameraNetwork) throws {
        if let verifyFailure { throw verifyFailure }
    }
    func leave(_ network: JoinedCameraNetwork) {}
    func drainPendingJoin() {}
}

actor FixtureWirelessSession: WirelessTransferSession {
    let identity: WirelessIdentity
    private let jpeg: Data
    private let raf: Data
    private let scenario: WirelessFixture.Mode
    private let transport: WirelessMode
    private var sessionID = UUID()
    private var closed = false
    private var enumerations = 0
    private var inventoryBarrier: FixtureBarrier?
    private var inventoryHeld = false
    private var closeBarrier: FixtureBarrier?
    private var downloadFailure: WirelessFailure?
    private var interruptPair = false
    private var didFailClose = false
    private(set) var closeCount = 0
    private(set) var thumbnailCount = 0
    private(set) var downloadCount = 0
    private(set) var commandsDuringInventory = 0

    init(identity: WirelessIdentity, scenario: WirelessFixture.Mode = .paired, transport: WirelessMode? = nil) throws {
        self.identity = identity
        self.scenario = scenario
        self.transport = transport ?? (identity.model == .xe3 ? .phone : .xApp)
        interruptPair = scenario == .recoverable
        (jpeg, raf) = try fixtureWirelessOriginals(model: identity.model)
    }

    var selections: [ImportSelection] {
        [true, false].enumerated().map { index, pair in
            let formats: [WirelessObjectFormat] = pair ? [.raf, .jpeg] : [.raf]
            let objects = formats.enumerated().map { offset, format in
                descriptor(photo: index + 1, handle: UInt32(index * 2 + offset + 1), format: format,
                           date: index == 0 ? "20200102T030405+0000" : "20200101T030405+0000")
            }
            return .init(captureID: .init(describing: objects), camera: identity, descriptors: objects,
                         policy: pair ? .pair : .rawOnly)
        }
    }

    private func descriptor(photo: Int, handle: UInt32, format: WirelessObjectFormat, date: String) -> WirelessObjectDescriptor {
        let rawSize = identity.model == .xe3 ? PixelSize(width: 6000, height: 4000) : PixelSize(width: 7728, height: 5152)
        return .init(cameraID: identity.cameraID, sessionID: sessionID, storageID: 1,
            handle: handle, directory: "DCIM/100_FUJI",
            filename: String(format: "DSCF%04d.%@", photo, format == .raf ? "RAF" : "JPG"),
            format: format, byteLength: UInt64((format == .raf ? raf : jpeg).count), captureDate: date,
            dimensions: format == .raf ? rawSize : .init(width: 6, height: 4), orientation: 1, hasThumbnail: true)
    }

    private var inventoryObjects: [WirelessObjectDescriptor] {
        if transport == .phone {
            return [descriptor(photo: 1, handle: 2, format: .jpeg, date: "20200102T030405+0000")]
        }
        let originals = selections.flatMap(\.descriptors)
        if scenario == .formats {
            return originals + [
                descriptor(photo: 3, handle: 4, format: .jpeg, date: "20191231T030405+0000"),
                descriptor(photo: 4, handle: 5, format: .raf, date: "20191230T030405+0000"),
                descriptor(photo: 4, handle: 6, format: .jpeg, date: "20191229T030405+0000"),
                descriptor(photo: 5, handle: 7, format: .raf, date: "20191228T030405+0000"),
                descriptor(photo: 5, handle: 8, format: .raf, date: "20191228T030405+0000")
            ]
        }
        return originals
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
        .init(mode: transport, rawExposure: transport == .phone ? .unavailable : .available, storageIDs: [1],
              originalSizeVerified: transport != .phone, evidenceID: "fixture")
    }
    func enumerate() throws -> AsyncThrowingStream<WirelessInventoryBatch, Error> {
        _ = try open()
        if transport == .autoSave && scenario == .autoSaveInventoryFailure { throw WirelessFailure.unavailableStorage }
        if inventoryHeld { commandsDuringInventory += 1; throw WirelessFailure.cameraBusy }
        enumerations += 1
        let objects = inventoryObjects
        let exposure = capabilities().rawExposure
        let batch = WirelessInventoryBatch(objects: objects, storageChanges: [1: .complete], rawExposure: exposure)
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
        } else if enumerations == 2, scenario == .formats {
            continuation.yield(.init(objects: Array(objects.prefix(1)), rawExposure: exposure))
            let finish = Task {
                do {
                    try await Task.sleep(for: .seconds(8))
                    continuation.yield(.init(objects: Array(objects.dropFirst()), storageChanges: [1: .complete],
                                             rawExposure: exposure))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in finish.cancel() }
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
        if interruptPair && object.handle == 2 {
            interruptPair = false
            throw WirelessFailure.connectionLost
        }
        guard inventoryObjects.contains(object), transport != .phone else { throw WirelessFailure.objectChanged }
        let original = object.format == .raf ? raf : jpeg
        if scenario == .slowImport {
            let middle = original.count / 2
            try await sink(original.prefix(middle))
            try await Task.sleep(for: .seconds(9))
            try await sink(original.suffix(from: middle))
        } else {
            try await sink(original)
        }
    }
    func close() async throws {
        if let barrier = closeBarrier {
            closeBarrier = nil
            await barrier.wait()
        }
        if scenario == .autoSaveCloseFailure && !didFailClose {
            didFailClose = true
            throw WirelessFailure.connectionLost
        }
        if !closed { closed = true; closeCount += 1 }
    }
}

private actor FixtureAutoSave: AutoSaveGateway {
    private let session: FixtureWirelessSession
    private let persistenceSuite: String?
    private var registration: AutoSaveRegistration?

    init(session: FixtureWirelessSession, persistenceSuite: String?) {
        self.session = session
        self.persistenceSuite = persistenceSuite
    }

    private var preferences: UserDefaults? { persistenceSuite.flatMap(UserDefaults.init(suiteName:)) }
    private static let registrationKey = "FixturePCSaveRegistration"

    func checkAvailability() {}

    func register(camera: SavedCamera, onRegistered: @escaping @Sendable () async throws -> Void) async throws -> AutoSaveRegistration {
        let identity = session.identity
        guard camera.id == identity.cameraID, let peerKey = identity.protocolPeerKey else {
            throw WirelessFailure.peerMismatch
        }
        try await onRegistered()
        try Task.checkCancellation()
        let value = AutoSaveRegistration(cameraID: camera.id, peerKey: peerKey, importer: "Fuji Studio", cameraName: camera.displayName)
        registration = value
        if let preferences {
            preferences.set(try JSONEncoder().encode(value), forKey: Self.registrationKey)
        }
        return value
    }

    func savedRegistration(for cameraID: WirelessCameraID) throws -> AutoSaveRegistration {
        if registration == nil, let data = preferences?.data(forKey: Self.registrationKey) {
            registration = try JSONDecoder().decode(AutoSaveRegistration.self, from: data)
        }
        guard let registration, registration.cameraID == cameraID else { throw WirelessFailure.autoSaveRegistrationRequired }
        return registration
    }

    func waitForSession(registration: AutoSaveRegistration) async throws -> any WirelessTransferSession {
        guard self.registration == registration else { throw WirelessFailure.peerMismatch }
        await session.begin()
        return session
    }

    func cancel() {}
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

    init(reader: FixtureLibrary?, verifySaves: Bool, providesPlaceholder: Bool = true, rejection: PhotoImportFailure? = nil) {
        self.reader = reader; self.verifySaves = verifySaves; self.providesPlaceholder = providesPlaceholder
        self.rejection = rejection
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
