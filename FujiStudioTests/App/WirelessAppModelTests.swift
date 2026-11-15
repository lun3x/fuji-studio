import FujiCameraCore
import XCTest
@testable import FujiStudio

@MainActor
final class WirelessAppModelTests: XCTestCase {
    func testWirelessFixtureFlagsRequireTheFlowFixtureRoute() {
        let paired = "--fixture-wireless-paired"
        XCTAssertEqual(FixtureEnvironment.route(arguments: ["--ui-fixtures", paired], unitHost: false), .flow)
        XCTAssertEqual(FixtureEnvironment.route(arguments: [paired], unitHost: false), .invalid)
        XCTAssertEqual(FixtureEnvironment.route(arguments: ["--workspace-fixture", paired], unitHost: false), .invalid)
        XCTAssertEqual(FixtureEnvironment.route(arguments: ["--wireless-protocol-probe", paired], unitHost: false), .invalid)
        XCTAssertEqual(FixtureEnvironment.route(arguments: ["--ui-fixtures", paired], unitHost: true), .unitHost)
    }

    func testInactivePreservesExplicitWiFiJoinAndBackgroundReconnectsOnlyBluetooth() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .paired)
        let model = AppModel(environment: fixture.environment)
        let wireless = fixture.wireless
        await model.start()
        try await waitUntil { model.wirelessState.bluetooth == .ready }
        let join = FixtureBarrier()
        await wireless.wifi.holdJoin(join)
        let connect = Task { await model.connectCameraWiFi() }
        defer { connect.cancel() }
        try await waitUntil { await wireless.wifi.joinCount == 1 }
        await join.entered()
        await model.sceneChanged(.inactive)
        await join.release()
        await connect.value
        XCTAssertEqual(model.wirelessState.wifi, .ready)
        XCTAssertEqual(model.wirelessState.activity, .inactive)
        await model.sceneChanged(.background)
        let closed = await wireless.session.closeCount
        XCTAssertEqual(closed, 1)
        await model.sceneChanged(.active)
        try await waitUntil { model.wirelessState.bluetooth == .ready }
        let joins = await wireless.wifi.joinCount
        let prompts = await wireless.bluetooth.reconnectPrompts
        let usbConnects = await fixture.camera.connectCount
        XCTAssertEqual(model.wirelessState.wifi, .idle)
        XCTAssertEqual(joins, 1)
        XCTAssertEqual(prompts, [false, false])
        XCTAssertEqual(usbConnects, 0)
        XCTAssertTrue(model.importEvents.isEmpty)
    }

    func testBackgroundClosesNativeSessionBeforePendingPhotosCallbackSettles() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .paired)
        let model = AppModel(environment: fixture.environment)
        await model.start()
        try await browse(model)
        let save = FixtureBarrier()
        await fixture.wireless.photos.holdCreate(save)
        await model.importSelectedCaptures()
        try await waitUntil { await fixture.wireless.photos.createCount == 1 }
        await save.entered()
        await model.reloadLibrary()
        XCTAssertFalse(model.sources.contains { $0.id == "wireless-1" })
        await model.sceneChanged(.inactive)
        let beforeBackground = await fixture.wireless.session.closeCount
        XCTAssertEqual(beforeBackground, 0)
        let background = Task { await model.sceneChanged(.background) }
        do {
            try await waitUntil { await fixture.wireless.session.closeCount == 1 }
        } catch {
            await save.release()
            await background.value
            throw error
        }
        await save.release()
        await background.value
        await model.sceneChanged(.active)
        let creates = await fixture.wireless.photos.createCount
        XCTAssertEqual(creates, 1)
        XCTAssertFalse(model.importEvents.contains(where: \.isRunning))
        XCTAssertEqual(model.wirelessState.wifi, .idle)
    }

    func testWirelessOwnershipBlocksManualUSBAndDoesNotMakeUSBCameraReady() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .paired)
        let model = AppModel(environment: fixture.environment)
        await model.start()
        try await browse(model)
        XCTAssertEqual(model.state.cameraState, .disconnected)
        XCTAssertFalse(model.canResetCameraConnection)
        XCTAssertFalse(model.state.canImportRecipes)
        await model.connect()
        await model.resetCameraConnection()
        let blockedUSB = await fixture.camera.connectCount
        XCTAssertEqual(blockedUSB, 0)
        await model.disconnectCameraWiFi()
        await model.connect()
        try await waitUntil { model.state.isCameraReady }
        let manualUSB = await fixture.camera.connectCount
        XCTAssertEqual(manualUSB, 1)
        try await waitUntil { model.wirelessState.bluetooth == .idle }
        await model.retryCameraBluetooth()
        try await waitUntil { model.wirelessState.bluetooth == .ready }
        XCTAssertEqual(model.state.cameraState, .disconnected)
    }

    func testVerifiedImportPreservesViewerUntilViewImported() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .paired)
        let settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        settings.updateOriginalInPhotos = true
        let model = AppModel(environment: fixture.environment, settings: settings)
        await model.start()
        model.send(.sourceTapped("source-0"))
        model.send(.select)
        try await browse(model)
        let viewer = model.state.viewedSourceID
        let selection = model.state.checkedSourceIDs
        let reloads = await fixture.reader.discoveryRequests
        await model.importSelectedCaptures()
        try await waitUntil { model.sources.count == 5 }
        try await waitUntil { await fixture.reader.wirelessInsertionNotificationCount == 2 }
        let event = try XCTUnwrap(model.importEvents.first { $0.receipts.count == 2 })
        let ids = event.receipts.map(\.assetID)
        XCTAssertEqual(ids, ["wireless-1", "wireless-2"])
        XCTAssertEqual(model.state.viewedSourceID, viewer)
        XCTAssertEqual(model.state.checkedSourceIDs, selection)
        let observedReloads = await fixture.reader.discoveryRequests
        let conversionSaves = await fixture.writer.requests
        XCTAssertEqual(observedReloads, reloads)
        XCTAssertTrue(conversionSaves.isEmpty)
        await model.viewImported(jobID: try XCTUnwrap(event.jobID))
        XCTAssertEqual(model.state.checkedSourceIDs, Set(ids))
        XCTAssertEqual(model.state.viewedSourceID, "wireless-1")
    }

    func testResumeWaitsForFullBrowserInventoryThenUsesFreshRouteEvidence() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .paired)
        let selections = await fixture.wireless.session.selections
        let job = try ImportJob(selections: selections, importDate: Date(), mode: .xApp)
        try await fixture.environment.wireless.journal.save(job)
        let model = AppModel(environment: fixture.environment)
        await model.start()
        let inventory = FixtureBarrier()
        await fixture.wireless.session.holdBrowserInventory(inventory)
        let connect = Task { await model.connectCameraWiFi() }
        try await waitUntil { model.wirelessState.wifi == .ready && model.cameraBrowser.isLoading }
        let resume = Task { await model.resumeImport(jobID: job.id) }
        try await waitUntil { model.isPreparingImport }
        await inventory.release()
        await connect.value
        await resume.value
        try await waitUntil { model.importEvents.contains { $0.receipts.count == 2 } }
        try await waitUntil {
            model.cameraBrowser.captures.count == 2 &&
                model.cameraBrowser.captures.allSatisfy { model.cameraBrowser.importReceiptStatus(for: $0) == .verified }
        }
        let commandsDuringInventory = await fixture.wireless.session.commandsDuringInventory
        XCTAssertEqual(commandsDuringInventory, 0)
    }

    func testInvalidatedDownloadRetiresWiFiAndLocalSkipDoesNotRetireNewSession() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .paired)
        let model = AppModel(environment: fixture.environment)
        await model.start()
        try await browse(model)
        await fixture.wireless.session.failNextDownload(.connectionLost)
        await model.importSelectedCaptures()
        try await waitUntil { model.wirelessState.wifi == .idle && model.importEvents.first?.invalidatedSession == true }
        let originalCloseCount = await fixture.wireless.session.closeCount
        XCTAssertEqual(originalCloseCount, 1)
        let jobID = try XCTUnwrap(model.importEvents.first?.jobID)
        await model.connectCameraWiFi()
        XCTAssertEqual(model.wirelessState.wifi, .ready)
        await model.skipImportCapture(jobID: jobID)
        let next = try XCTUnwrap(model.importEvents.first)
        try await waitUntil { model.importEvents.first?.captureIndex == 1 }
        XCTAssertEqual(next.jobID, jobID)
        XCTAssertEqual(model.wirelessState.wifi, .ready)
        let closeCount = await fixture.wireless.session.closeCount
        XCTAssertEqual(closeCount, 1)
    }

    func testUnverifiedPlaceholderDoesNotBecomeAnImportedTraySourceOnLibraryChange() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .unverifiedSave)
        let model = AppModel(environment: fixture.environment)
        await model.start()
        try await browse(model)
        await model.importSelectedCaptures()
        try await waitUntil { model.importEvents.contains { $0.stage == .savedUnverified } }
        let event = try XCTUnwrap(model.importEvents.first)
        XCTAssertTrue(event.receipts.isEmpty)
        await model.reloadLibrary()
        await model.viewImported(jobID: try XCTUnwrap(event.jobID))
        XCTAssertFalse(model.sources.contains { $0.id == "wireless-1" })
        XCTAssertNil(model.state.viewedSourceID)
        let relaunched = AppModel(environment: fixture.environment)
        await relaunched.start()
        XCTAssertFalse(relaunched.sources.contains { $0.id == "wireless-1" })
        XCTAssertEqual(relaunched.sources.count, 3)
    }

    func testUnknownSubmissionHidesMatchingPhotosWhileKeepingUnrelatedSourcesVisible() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .unidentifiedSave)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2020-01-02T03:04:05Z"))
        await fixture.reader.insertExternalRAW("existing-other-import", filename: "DSCF0001.RAF", date: date)
        let model = AppModel(environment: fixture.environment)
        await model.start()
        model.send(.sourceTapped("existing-other-import"))
        model.send(.select)
        try await browse(model)
        await model.importSelectedCaptures()
        try await waitUntil { model.importEvents.first?.pauseReason == .unresolvedSave }
        await model.reloadLibrary()
        XCTAssertEqual(model.state.viewedSourceID, "existing-other-import")
        XCTAssertEqual(model.state.checkedSourceIDs, ["existing-other-import"])
        let relaunched = AppModel(environment: fixture.environment)
        await relaunched.start()
        XCTAssertEqual(Set(relaunched.sources.map(\.id)), ["existing-other-import", "source-0", "source-1", "source-2"])
        XCTAssertFalse(relaunched.sources.contains { $0.id == "wireless-1" })
        XCTAssertTrue(relaunched.importRecoveryEvents.first?.actions.contains(.managePhotos) == true)
    }

    func testStartupRestoresUnfinishedQueueWithoutConnectingOrSubmitting() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .paired)
        let captures = await fixture.wireless.session.selections
        let job = try ImportJob(selections: captures, importDate: Date(), mode: .xApp)
        try await fixture.environment.wireless.journal.save(job)
        let model = AppModel(environment: fixture.environment)
        await model.start()
        try await waitUntil { model.wirelessState.bluetooth == .ready }
        XCTAssertEqual(model.importRecoveryEvents.map(\.jobID), [job.id])
        XCTAssertEqual(model.importRecoveryEvents.first?.pauseReason, .interrupted)
        let joins = await fixture.wireless.wifi.joinCount
        let creates = await fixture.wireless.photos.createCount
        XCTAssertEqual(joins, 0)
        XCTAssertEqual(creates, 0)
    }

    func testJournalFailureSurfacesGlobalRecoveryIssueAndRetainsTheCurrentTray() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .paired)
        let model = AppModel(environment: fixture.environment)
        await model.start()
        model.send(.sourceTapped("source-0"))
        let file = fixture.wireless.journalRoot.appendingPathComponent(UUID().uuidString + ".json")
        try Data("invalid journal".utf8).write(to: file)
        await fixture.reader.insertExternalRAW("unclassified", filename: "OTHER.RAF", date: Date())
        await model.reloadLibrary()
        await model.sceneChanged(.active)
        XCTAssertEqual(model.state.viewedSourceID, "source-0")
        XCTAssertEqual(model.sources.count, 3)
        XCTAssertEqual(model.importJournalIssue?.recoveryRequired, true)
        XCTAssertNil(model.importJournalIssue?.jobID)

        let relaunched = AppModel(environment: fixture.environment)
        await relaunched.start()
        XCTAssertEqual(Set(relaunched.sources.map(\.id)), ["source-0", "source-1", "source-2"])
        XCTAssertEqual(relaunched.importJournalIssue?.recoveryRequired, true)
    }

    private func browse(_ model: AppModel) async throws {
        await model.connectCameraWiFi()
        try await waitUntil { model.cameraBrowser.canSelectOriginals && !model.cameraBrowser.isLoading }
        for capture in model.cameraBrowser.captures {
            try model.cameraBrowser.select(capture.id, policy: capture.jpeg == nil ? .rawOnly : .pair)
        }
    }

    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while !(await condition()) {
            if clock.now > deadline {
                XCTFail("Timed out waiting for model state", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
