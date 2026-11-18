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

    func testCancellingPresentedAutoSaveBeforeItsTaskRunsDoesNotStartTransfer() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .autoSave)
        let model = AppModel(environment: fixture.environment)
        await model.start()
        let presentation = PresentedCameraConnection()
        presentation.start(from: .autoSave) { await model.setUpCameraAutoSave() }
        presentation.cancel(from: .autoSave) { pending in await model.cancelWirelessConnection(draining: pending) }
        try await waitUntil { !presentation.isWorking }
        XCTAssertNil(model.wirelessState.transferRoute)
        XCTAssertNil(model.wirelessState.verifiedAutoSaveCameraID)
        XCTAssertFalse(model.state.wirelessRestrictsUSB)
    }

    func testCancellingAdmittedDiscoveryWithoutObserverUpdateRestoresUSBOnlyAfterDrain() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .unpaired)
        let model = AppModel(environment: fixture.environment)
        await model.start()
        try await waitUntil { model.state.isCameraReady && model.canResetCameraConnection }
        let initialConnects = await fixture.camera.connectCount
        let pendingRead = FixtureBarrier()
        defer { Task { await pendingRead.release() } }
        model.validationDropDiscoveryUpdates = true
        model.validationDiscoveryStateRead = pendingRead
        let presentation = PresentedCameraConnection()
        presentation.start(from: .status) { await model.discoverWirelessCameras() }
        let coordinator = fixture.environment.wireless.connection
        try await waitUntil { await coordinator.currentState().bluetooth == .discovering }
        await pendingRead.entered()
        let admitted = await coordinator.currentState()
        XCTAssertEqual(admitted.bluetooth, .discovering)
        XCTAssertEqual(model.wirelessState.bluetooth, .idle)
        XCTAssertFalse(model.canResetCameraConnection)

        presentation.cancel { pending in await model.cancelWirelessConnection(draining: pending) }
        try await waitUntil { await coordinator.currentState().bluetooth == .idle }
        XCTAssertTrue(presentation.isWorking)
        XCTAssertFalse(model.canResetCameraConnection)
        let connectsWhileDraining = await fixture.camera.connectCount
        XCTAssertEqual(connectsWhileDraining, initialConnects)
        await pendingRead.release()

        try await waitUntil { !presentation.isWorking }
        try await waitUntil { model.state.isCameraReady && model.canResetCameraConnection }
        let finalConnects = await fixture.camera.connectCount
        XCTAssertGreaterThan(finalConnects, initialConnects)
        XCTAssertEqual(model.wirelessState.bluetooth, .idle)
    }

    func testCancellingPresentedConnectionKeepsAdmittedTransfer() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .paired)
        let model = AppModel(environment: fixture.environment)
        await model.start()
        let inventory = FixtureBarrier()
        await fixture.wireless.session.holdBrowserInventory(inventory)
        let presentation = PresentedCameraConnection()
        presentation.start(from: .status) { await model.connectCameraWiFi() }
        try await waitUntil { model.wirelessState.wifi == .ready && model.cameraBrowser.isLoading }
        XCTAssertTrue(presentation.isWorking)
        presentation.cancel { pending in await model.cancelWirelessConnection(draining: pending) }
        await inventory.release()
        try await waitUntil { !presentation.isWorking }
        let closeCount = await fixture.wireless.session.closeCount
        XCTAssertEqual(closeCount, 0)
        XCTAssertEqual(model.wirelessState.wifi, .ready)
        XCTAssertTrue(model.wirelessState.hasTransferLease)
    }

    func testImportRecoveryRebuildsCameraAndFileContextFromJournalAfterForget() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .recoverable)
        let model = AppModel(environment: fixture.environment)
        await model.start()
        try await browse(model)
        let original = try XCTUnwrap(model.cameraBrowser.captures.first { $0.availability == .pair })
        try model.cameraBrowser.select(original.id, policy: .pair)
        await model.importSelectedCaptures()
        try await waitUntil { model.importRecoveryEvents.first?.pauseReason == .connectionLost }
        try await waitUntil { model.wirelessState.wifi == .idle }
        let first = try XCTUnwrap(model.importRecoveryEvents.first)
        let cameraID = try XCTUnwrap(first.cameraID)
        await model.forgetWirelessCamera(cameraID)
        XCTAssertFalse(model.wirelessState.savedCameras.contains { $0.id == cameraID })
        let recovered = AppModel(environment: fixture.environment)
        await recovered.start()
        try await waitUntil { recovered.importRecoveryEvents.first?.jobID == first.jobID }
        let context = try XCTUnwrap(recovered.importRecoveryEvents.first?.jobContext)
        XCTAssertEqual(context, first.jobContext)
        XCTAssertEqual(context.cameraDisplayName, "Fixture X-T5")
        XCTAssertEqual(context.cameraModel, .xt5)
        XCTAssertEqual(context.firstFilename, original.rowID.filename)
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

    func testStartupWaitsForSavedCameraPreferenceBeforeAutomaticUSBDiscovery() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .paired)
        let selectionRead = FixtureBarrier()
        await fixture.wireless.holdSavedCameraSelectionRead(selectionRead)
        let model = AppModel(environment: fixture.environment)
        let start = Task { await model.start() }
        defer { Task { await selectionRead.release() } }

        await selectionRead.entered()
        try await waitUntil { model.wirelessState.activity == .active }
        XCTAssertNil(model.wirelessState.selectedCameraID)
        let connectsWhileReading = await fixture.camera.connectCount
        XCTAssertEqual(connectsWhileReading, 0)

        await selectionRead.release()
        await start.value
        try await waitUntil { model.wirelessState.bluetooth == .ready }
        let usbConnects = await fixture.camera.connectCount
        let prompts = await fixture.wireless.bluetooth.reconnectPrompts
        XCTAssertEqual(usbConnects, 0)
        XCTAssertEqual(prompts, [false])
    }

    func testStartupBeginsAutomaticUSBDiscoveryWhenSavedPreferenceIsEmpty() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .unpaired)
        let selectionRead = FixtureBarrier()
        await fixture.wireless.holdSavedCameraSelectionRead(selectionRead)
        let model = AppModel(environment: fixture.environment)
        let start = Task { await model.start() }
        defer { Task { await selectionRead.release() } }

        await selectionRead.entered()
        try await waitUntil { model.wirelessState.activity == .active }
        let connectsWhileReading = await fixture.camera.connectCount
        XCTAssertEqual(connectsWhileReading, 0)

        await selectionRead.release()
        await start.value
        try await waitUntil { model.state.isCameraReady }
        let usbConnects = await fixture.camera.connectCount
        XCTAssertEqual(usbConnects, 1)
    }

    func testUnreadableSavedPreferenceReportsFailureAndAllowsExplicitUSBDiscovery() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .paired)
        await fixture.wireless.failSavedCameraSelectionRead()
        let model = AppModel(environment: fixture.environment)
        await model.start()

        XCTAssertEqual(model.wirelessState.failure, .savedSettingsUnavailable)
        let automaticUSBConnects = await fixture.camera.connectCount
        XCTAssertEqual(automaticUSBConnects, 0)

        await model.connect()
        try await waitUntil { model.state.isCameraReady }
        let manualUSBConnects = await fixture.camera.connectCount
        XCTAssertEqual(manualUSBConnects, 1)
    }

    func testStagedRetryFinishesWhileReconnectedCameraInventoryIsStillLoading() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .paired)
        let model = AppModel(environment: fixture.environment)
        await model.start()
        try await browse(model)
        let pair = try XCTUnwrap(model.cameraBrowser.captures.first { $0.availability == .pair })
        for capture in model.cameraBrowser.captures where capture.id != pair.id {
            model.cameraBrowser.deselect(capture.id)
        }
        await fixture.wireless.photos.rejectNextCreate(.storage)
        await model.importSelectedCaptures()
        try await waitUntil { model.importEvents.first?.pauseReason == .storage && !model.cameraImportActive }
        let id = try XCTUnwrap(model.importEvents.first?.jobID)
        await model.disconnectCameraWiFi()
        let scan = FixtureBarrier()
        await fixture.wireless.session.holdBrowserInventory(scan)
        let reconnect = Task { await model.connectCameraWiFi() }
        defer { Task { await scan.release() } }
        await scan.entered()
        let retry = Task { await model.retryImportCapture(jobID: id) }
        try await waitUntil { model.importEvents.first?.receipts.count == 1 }
        XCTAssertTrue(model.cameraBrowser.isLoading)
        await scan.release()
        await retry.value
        await reconnect.value
    }

    func testLocalPhotosRetryKeepsScreenAwakeAndBlocksCameraChoiceUntilSettlement() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .twoSaved)
        let model = AppModel(environment: fixture.environment)
        await model.start()
        try await browse(model)
        let first = try XCTUnwrap(model.cameraBrowser.captures.first { $0.availability == .pair })
        for capture in model.cameraBrowser.captures where capture.id != first.id {
            model.cameraBrowser.deselect(capture.id)
        }
        await fixture.wireless.photos.rejectNextCreate(.authorization)
        await model.importSelectedCaptures()
        try await waitUntil { model.importEvents.first?.pauseReason == .photosAccess && !model.cameraImportActive }
        XCTAssertFalse(fixture.platform.idleTimerDisabled)
        let jobID = try XCTUnwrap(model.importEvents.first?.jobID)
        await model.disconnectCameraWiFi()
        let selected = try XCTUnwrap(model.wirelessState.selectedCameraID)
        let alternate = try XCTUnwrap(model.wirelessState.savedCameras.first { $0.id != selected }?.id)

        let heldSave = FixtureBarrier()
        await fixture.wireless.photos.holdCreate(heldSave)
        defer { Task { await heldSave.release() } }
        await model.retryImportCapture(jobID: jobID)
        await heldSave.entered()
        try await waitUntil { model.cameraImportActive }
        XCTAssertTrue(fixture.platform.idleTimerDisabled)
        XCTAssertFalse(model.wirelessState.hasTransferLease)
        let status = WirelessStatusSummary(state: model.wirelessState, activeImport: model.activeCameraImport)
        XCTAssertEqual(status?.label, "Saving photo 1 of 1 to Photos")
        XCTAssertEqual(status?.importCounts, "0 of 1 photo imported")
        await model.selectWirelessCamera(alternate)
        await model.discoverWirelessCameras()
        await model.forgetWirelessCamera(selected)
        XCTAssertEqual(model.wirelessState.selectedCameraID, selected)
        XCTAssertEqual(model.wirelessState.savedCameras.count, 2)
        XCTAssertNotEqual(model.wirelessState.bluetooth, .discovering)

        await heldSave.release()
        try await waitUntil { !model.cameraImportActive && model.importEvents.first?.receipts.count == 1 }
        XCTAssertFalse(fixture.platform.idleTimerDisabled)
        let settledStatus = WirelessStatusSummary(state: model.wirelessState, activeImport: model.activeCameraImport)
        XCTAssertNil(settledStatus?.importCounts)
        XCTAssertNotEqual(settledStatus?.label, status?.label)
        await model.selectWirelessCamera(alternate)
        XCTAssertEqual(model.wirelessState.selectedCameraID, alternate)
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
        try await waitUntil { model.cameraImportActive }
        XCTAssertTrue(fixture.platform.idleTimerDisabled)
        await model.reloadLibrary()
        XCTAssertFalse(model.sources.contains { $0.id == "wireless-1" })
        await model.sceneChanged(.inactive)
        let beforeBackground = await fixture.wireless.session.closeCount
        XCTAssertEqual(beforeBackground, 0)
        let background = Task { await model.sceneChanged(.background) }
        do {
            try await waitUntil { await fixture.wireless.session.closeCount == 1 }
            XCTAssertFalse(fixture.platform.idleTimerDisabled)
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

    func testOverlappingBackgroundAndActiveRequestsKeepTheFirstNativeCloseFenced() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .paired)
        let model = AppModel(environment: fixture.environment)
        await model.start()
        try await browse(model)
        let close = FixtureBarrier()
        await fixture.wireless.session.holdClose(close)
        let revision = model.validationScene.revision
        let firstBackground = Task { await model.sceneChanged(.background) }
        await close.entered()
        let selections = await fixture.wireless.session.selections
        let queued = try ImportJob(selections: selections, importDate: Date(), mode: .xApp)
        try await fixture.environment.wireless.journal.save(queued)
        let firstActive = Task { await model.sceneChanged(.active) }
        try await waitUntil { model.validationScene.revision == revision + 2 }
        let secondBackground = Task { await model.sceneChanged(.background) }
        try await waitUntil { model.validationScene.revision == revision + 3 }
        let secondActive = Task { await model.sceneChanged(.active) }
        try await waitUntil { model.validationScene.revision == revision + 4 }
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(100)
        while clock.now < deadline, model.wirelessState.activity == .background, model.importRecoveryEvents.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        let held = await fixture.environment.wireless.connection.currentState()
        XCTAssertEqual(held.activity, .background)
        XCTAssertTrue(model.importRecoveryEvents.isEmpty)
        await close.release()
        await firstBackground.value
        await firstActive.value
        await secondBackground.value
        await secondActive.value
        XCTAssertEqual(model.wirelessState.activity, .active)
        XCTAssertEqual(model.importRecoveryEvents.map(\.jobID), [queued.id])
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

    func testPausedLoanBlocksThumbnailsAndNativeLossMakesRetryLocalOnly() async throws {
        let fixture = try await FixtureEnvironment.make(wireless: .paired)
        let model = AppModel(environment: fixture.environment)
        await model.start()
        try await browse(model)
        let first = try XCTUnwrap(model.cameraBrowser.captures.first)
        XCTAssertNotNil(first.thumbnailObject)
        await fixture.wireless.photos.rejectNextCreate(.authorization)
        await model.importSelectedCaptures()
        try await waitUntil { model.importEvents.first?.pauseReason == .photosAccess && model.importEvents.first?.isRunning == false }
        let paused = try XCTUnwrap(model.importEvents.first)
        let jobID = try XCTUnwrap(paused.jobID)
        XCTAssertFalse(paused.needsSession)
        let preview = await model.cameraBrowser.thumbnail(for: first)
        let previewAttempts = await fixture.wireless.session.thumbnailCount
        XCTAssertNil(preview)
        XCTAssertEqual(previewAttempts, 0)

        // Simulate loss emitted by the connection owner independently of the app action.
        await fixture.environment.wireless.connection.disconnectWiFi()
        try await waitUntil {
            let event = await fixture.environment.wireless.importer.latestEvent(jobID: jobID)
            return model.wirelessState.wifi == .idle && event?.needsSession == true
        }
        let loanAfterLoss = await fixture.environment.wireless.importer.latestEvent(jobID: jobID)
        XCTAssertEqual(loanAfterLoss?.needsSession, true)
        await model.connectCameraWiFi()
        let second = try XCTUnwrap(model.cameraBrowser.captures.first)
        XCTAssertNotEqual(first.rowID.sessionID, second.rowID.sessionID)
        let newPreview = await model.cameraBrowser.thumbnail(for: second)
        XCTAssertNotNil(newPreview)
        let beforeRetry = await fixture.wireless.session.downloadCount
        await model.retryImportCapture(jobID: jobID)
        try await waitUntil { model.importEvents.first?.isRunning == false && model.importEvents.first?.receipts.isEmpty == false }
        let afterRetry = await fixture.wireless.session.downloadCount
        XCTAssertEqual(afterRetry, beforeRetry)
        XCTAssertEqual(model.importEvents.first?.receipts.count, 1)
        XCTAssertEqual(model.importEvents.first?.captureIndex, 1)
        XCTAssertEqual(model.wirelessState.wifi, .ready)
    }

    func testFastUnresolvedSaveCannotEnterAnyLibraryBatchOrBecomeCataloged() async throws {
        for mode in [WirelessFixture.Mode.unverifiedSave, .unidentifiedSave] {
            let fixture = try await FixtureEnvironment.make(wireless: mode)
            let model = AppModel(environment: fixture.environment)
            await model.start()
            try await browse(model)
            let beforeSnapshot = FixtureBarrier(), afterMarker = FixtureBarrier()
            await fixture.reader.holdNextDiscovery(beforeSnapshot: beforeSnapshot, afterID: "scan-marker", afterYield: afterMarker)
            await fixture.wireless.photos.suppressInsertionNotifications()
            let firstScan = Task { await model.reloadLibrary() }
            await beforeSnapshot.entered()
            await model.importSelectedCaptures()
            try await waitUntil { model.importEvents.first?.pauseReason == .unresolvedSave && model.importEvents.first?.isRunning == false }
            await fixture.reader.insertExternalRAW("scan-marker", filename: "EXTERNAL.RAF", date: Date(), notify: false)
            await beforeSnapshot.release()
            try await waitUntil { model.sources.contains { $0.id == "scan-marker" } }
            XCTAssertFalse(model.sources.contains { $0.id == "wireless-1" }, String(describing: mode))
            await model.reloadLibrary()
            await afterMarker.release()
            await firstScan.value
            XCTAssertFalse(model.sources.contains { $0.id == "wireless-1" }, String(describing: mode))
            let root = fixture.wireless.journalRoot.deletingLastPathComponent()
            let catalog = try SwiftDataCatalog(storeURL: root.appendingPathComponent("catalog.store"))
            let persisted = try await catalog.knownSourceIDs()
            XCTAssertFalse(persisted.contains("wireless-1"), String(describing: mode))
            XCTAssertTrue(persisted.contains("scan-marker"))
        }
    }

    func testLimitedKnownInsertionMergesIncrementallyAndRealScopeChangeReloads() async throws {
        let fixture = try await FixtureEnvironment.make(access: .limited, wireless: .paired)
        let model = AppModel(environment: fixture.environment)
        await model.start()
        model.send(.sourceTapped("source-0"))
        model.send(.select)
        try await browse(model)
        let initial = await fixture.reader.discoveryRequests
        await model.importSelectedCaptures()
        try await waitUntil { model.sources.count == 5 && model.importEvents.first?.receipts.count == 2 }
        let afterImport = await fixture.reader.discoveryRequests
        XCTAssertEqual(afterImport, initial)
        XCTAssertEqual(model.state.viewedSourceID, "source-0")
        XCTAssertEqual(model.state.checkedSourceIDs, ["source-0"])
        await fixture.reader.insertExternalRAW("newly-shared", filename: "EXTERNAL.RAF", date: Date())
        try await waitUntil { model.sources.contains { $0.id == "newly-shared" } && !model.isLoadingLibrary }
        let afterScopeChange = await fixture.reader.discoveryRequests
        XCTAssertEqual(afterScopeChange, initial + 1)
        XCTAssertEqual(model.state.libraryAccess, .limited)
    }

    func testLimitedGrantCanMakePreviouslyImportedPhotoVisibleAgain() async throws {
        let fixture = try await FixtureEnvironment.make(access: .limited, wireless: .paired)
        let model = AppModel(environment: fixture.environment)
        await model.start()
        try await browse(model)
        await model.importSelectedCaptures()
        try await waitUntil { model.sources.count == 5 }
        let photo = try await fixture.reader.source(id: "wireless-1")
        await fixture.reader.removeReplacedOriginals([photo.id])
        try await waitUntil { model.sources.count == 4 && !model.isLoadingLibrary }
        await fixture.reader.grantLimitedAccess(to: photo)
        try await waitUntil { model.sources.contains { $0.id == photo.id } }
    }

    func testFirstLimitedGrantReconcilesSettledPlaceholderWithoutAnotherCreate() async throws {
        let fixture = try await FixtureEnvironment.make(access: .limited, wireless: .paired)
        let model = AppModel(environment: fixture.environment)
        await model.start()
        model.send(.sourceTapped("source-0"))
        model.send(.select)
        try await browse(model)
        await fixture.wireless.photos.hideNextSaveFromLibrary()
        await model.importSelectedCaptures()
        try await waitUntil {
            model.importEvents.first?.pauseReason == .unresolvedSave && model.importEvents.first?.isRunning == false
        }
        let jobID = try XCTUnwrap(model.importEvents.first?.jobID)
        let job = try await fixture.environment.wireless.importer.recovery.load(jobID)
        let placeholder = try XCTUnwrap(job.captures.first?.placeholderAssetID)
        XCTAssertEqual(placeholder, "wireless-1")
        let priorInsertions = await fixture.reader.wirelessInsertionNotificationCount
        XCTAssertEqual(priorInsertions, 0)
        XCTAssertTrue(model.importEvents.first?.receipts.isEmpty == true)
        XCTAssertFalse(model.sources.contains { $0.id == placeholder })

        // Present the limited picker and let its immediate read-only check finish
        // while the user has yet to grant access to the new asset.
        await model.manageImportPhotos()
        XCTAssertEqual(fixture.platform.manageCalls, 1)
        XCTAssertTrue(model.importEvents.first?.receipts.isEmpty == true)
        let revision = model.validationScene.revision
        let discoveryRequests = await fixture.reader.discoveryRequests
        await fixture.wireless.photos.grantLibraryAccess(to: placeholder)
        try await waitUntil {
            model.importEvents.first?.receipts.map(\.assetID) == [placeholder] &&
                model.sources.contains { $0.id == placeholder }
        }
        let afterGrant = try await fixture.environment.wireless.importer.recovery.load(jobID)
        XCTAssertEqual(afterGrant.captures.first?.receipt?.assetID, placeholder)
        let creates = await fixture.wireless.photos.createCount
        XCTAssertEqual(creates, 1)
        XCTAssertEqual(model.validationScene.revision, revision)
        XCTAssertEqual(model.state.viewedSourceID, "source-0")
        XCTAssertEqual(model.state.checkedSourceIDs, ["source-0"])
        let observedDiscoveries = await fixture.reader.discoveryRequests
        XCTAssertEqual(observedDiscoveries, discoveryRequests)
    }

    func testLimitedGrantQueuesFreshReadWhenPickerProbeAlreadyReadOldAccess() async throws {
        let fixture = try await FixtureEnvironment.make(access: .limited, wireless: .paired)
        let model = AppModel(environment: fixture.environment)
        await model.start()
        try await browse(model)
        await fixture.wireless.photos.hideNextSaveFromLibrary()
        await model.importSelectedCaptures()
        try await waitUntil {
            model.importEvents.first?.pauseReason == .unresolvedSave && model.importEvents.first?.isRunning == false
        }
        let holdOldRead = FixtureBarrier()
        await fixture.wireless.photos.holdNextInspection(holdOldRead)
        let earlierCheck = Task { await model.manageImportPhotos() }
        await holdOldRead.entered()
        await fixture.wireless.photos.grantLibraryAccess(to: "wireless-1")
        // The ordinary change stream handles these events in order. A separate
        // edit with no access change signals that the grant has been consumed.
        await fixture.reader.insertExternalRAW("stream-marker", filename: "MARKER.RAF", date: Date(), notify: false)
        await fixture.reader.revertEdit("source-0")
        do {
            try await waitUntil { model.sources.contains { $0.id == "stream-marker" } }
        } catch {
            await holdOldRead.release()
            await earlierCheck.value
            throw error
        }
        XCTAssertTrue(model.importEvents.first?.receipts.isEmpty == true)
        XCTAssertFalse(model.sources.contains { $0.id == "wireless-1" })
        await holdOldRead.release()
        await earlierCheck.value
        try await waitUntil {
            model.importEvents.first?.receipts.map(\.assetID) == ["wireless-1"] &&
                model.sources.contains { $0.id == "wireless-1" }
        }
        let creates = await fixture.wireless.photos.createCount
        XCTAssertEqual(creates, 1)
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
