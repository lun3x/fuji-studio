import SwiftUI
import Testing
@testable import FujiStudio

@MainActor struct AppModelTests {
    @Test func startOwnsOneSubscriptionAndPairedDisplayNeverMaterializesRAW() async throws {
        let f = try await FixtureEnvironment.make()
        let model = AppModel(environment: f.environment)
        await model.start(); await model.start()
        model.send(.sourceTapped("source-0"))
        await eventually { model.displayFile != nil }
        #expect(model.state.displayedVersion == .cameraJPEG)
        #expect(await f.reader.rawReads == 0)
        #expect(await f.reader.changeSubscriptions == 1)
        #expect(await f.camera.subscriptions == 1)
        #expect(await f.writer.requests.isEmpty)
    }

    @Test func lateAllCannotUndoNoneOrDone() async throws {
        let f = try await FixtureEnvironment.make(), barrier = FixtureBarrier()
        let model = AppModel(environment: f.environment)
        await model.start()
        await f.reader.holdAll(barrier)
        model.send(.select); model.send(.all(accessibleEligibleSourceIDs: []))
        await barrier.entered()
        #expect(model.isSelectingAll)
        model.send(.none); model.send(.done)
        await barrier.release()
        await eventually { !model.isSelectingAll }
        #expect(!model.state.isSelecting)
        #expect(model.state.checkedSourceIDs.isEmpty)
    }

    @Test func readyBusyReadyImportsSevenOnlyOnceAndRefreshFailureRetainsThem() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        await model.start(); await model.connect()
        await eventually { model.state.recipes.count == 7 && !model.isRefreshing && model.state.recipes.first?.cameraContext.sessionIdentity == model.state.currentCameraExecutionContext?.sessionIdentity }
        let snapshots = model.state.recipes
        await f.camera.cycleBusyReady()
        await eventually { model.state.cameraState == .ready(await f.camera.session) }
        #expect(await f.camera.importCount == 1)
        await f.camera.failImport()
        await model.refreshRecipes()
        #expect(model.state.recipes == snapshots)
        guard case .stale = model.state.recipeRefreshState else { Issue.record("Failed refresh lost stale status"); return }
    }

    @Test func deniedAndLimitedAccessHaveActionsWithoutCameraConnection() async throws {
        let f = try await FixtureEnvironment.make(access: .denied), model = AppModel(environment: f.environment)
        await model.start()
        #expect(model.sources.isEmpty)
        #expect(model.state.libraryAccess == .denied)
        model.openSettings(); #expect(f.platform.settingsCalls == 1)
        await f.reader.setAccess(.limited)
        await model.reloadLibrary()
        #expect(model.sources.count == 3)
        model.managePhotos(); #expect(f.platform.manageCalls == 1)
        #expect(await f.camera.connectCount == 0)
    }

    @Test func scopeNarrowingAfterCompletedExportRetainsSavedVersion() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        await model.start(); await model.connect()
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil }
        await model.export()
        await eventually { model.exportEvent?.terminal == true }
        #expect(model.exportEvent?.summary.completed == 1)
        await f.reader.restrictTo(["source-1"])
        await model.reloadLibrary()
        #expect(Set(model.sources.map(\.id)) == ["source-1"])
        #expect(model.state.viewedSourceID == nil)
        #expect(try await f.environment.catalog.versions(sourceID: "source-0").count == 1)
        #expect(await f.writer.requests.count == 1)
    }

    @Test func scopeNarrowingDuringHeldOriginalPreparationRetainsOnlyCompletedOutput() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment), barrier = FixtureBarrier()
        defer { Task { await barrier.release() } }
        await model.start(); await model.connect()
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil }
        model.send(.select); model.send(.checkedSourcesReplaced(["source-0", "source-2"]))
        await eventually { model.preview?.sourceID == "source-0" }
        #expect(model.state.checkedSourceIDs == ["source-0", "source-2"])
        await f.reader.holdMaterialize("source-2", barrier: barrier)
        await model.export(); await barrier.entered()
        await eventually { model.exportEvent?.summary.completed == 1 }
        let id = try #require(model.exportEvent?.jobID)
        let preparing = try await f.environment.catalog.job(id: id)
        #expect(preparing.items.first(where: { $0.source.id == "source-2" })?.state == .preparing)
        await f.reader.restrictTo(["source-1"])
        let reload = Task { await model.reloadLibrary() }
        await eventually { model.sources.count == 1 && model.exportEvent?.stopRequested == true }
        await barrier.release(); await reload.value
        await eventually { model.exportEvent?.terminal == true }
        #expect(model.exportEvent?.summary.completed == 1)
        #expect(try await f.environment.catalog.versions(sourceID: "source-0").count == 1)
        #expect(try await f.environment.catalog.versions(sourceID: "source-2").isEmpty)
        #expect(await f.writer.requests.count == 1)
    }

    @Test func backgroundPausesSubmittedSaveBeforeDisconnectAndRestoresPriorIdleTimer() async throws {
        let f = try await FixtureEnvironment.make(), barrier = FixtureBarrier()
        f.platform.idleTimerDisabled = true
        let model = AppModel(environment: f.environment)
        await model.start(); await model.connect()
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil }
        model.send(.select); model.send(.all(accessibleEligibleSourceIDs: []))
        await eventually { model.state.checkedSourceIDs.count == 3 }
        await f.writer.holdSave(barrier)
        await model.export(); await barrier.entered()
        model.send(.recipeSelected(slot: 2)) // Queued preview must never run after pause.
        let background = Task { await model.sceneChanged(.background) }
        await eventually { model.exportEvent?.stopRequested == true }
        #expect(await f.camera.disconnectCount == 0)
        #expect(f.platform.idleTimerDisabled)
        let foreground = Task { await model.sceneChanged(.active) }
        await barrier.release(); await background.value; await foreground.value
        #expect(await f.writer.requests.count == 1)
        #expect(model.exportEvent?.summary.completed == 1)
        #expect(model.exportEvent?.summary.unprocessed == 2)
        #expect(model.exportEvent?.terminal == true)
        #expect(model.state.activeJobID == nil)
        #expect(f.platform.idleTimerDisabled)
        #expect(await f.camera.disconnectCount == 1)
        #expect(await f.camera.connectCount == 2)
        #expect(await f.camera.renderCount == 1)
    }

    @Test func uncertainPreviewNeverAutomaticallyReplaysOnForegroundOrRecipeImport() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        await model.start(); await model.connect()
        await eventually { !model.isRefreshing && model.state.currentCameraExecutionContext != nil }
        await f.camera.failRender()
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { await f.camera.renderCount == 1 && model.state.currentCameraExecutionContext == nil }
        await model.sceneChanged(.background); await model.sceneChanged(.active)
        await model.connect()
        await eventually { !model.isRefreshing && model.state.currentCameraExecutionContext != nil }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await f.camera.renderCount == 1)
        model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil }
        #expect(await f.camera.renderCount == 2)
    }

    @Test func incrementalDiscoveryDoesNotPruneViewedSourceAfterFirstBatchAndAllUsesCompleteIndex() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        await model.start(); model.send(.sourceTapped("source-2"))
        let barrier = FixtureBarrier(); await f.reader.holdDiscovery(barrier)
        let reload = Task { await model.reloadLibrary() }
        await barrier.entered()
        #expect(model.state.viewedSourceID == "source-2")
        #expect(model.sources.count == 3)
        await barrier.release(); await reload.value
        await f.reader.limitDiscovery(1); await model.reloadLibrary()
        #expect(model.sources.count == 1)
        model.send(.select); model.send(.all(accessibleEligibleSourceIDs: []))
        await eventually { !model.isSelectingAll }
        #expect(model.sources.count == 3)
        #expect(model.state.checkedSourceIDs == ["source-0", "source-1", "source-2"])
    }

    @Test func manualSourceSwitchRejectsLateStoredBytesAndRetainsLeaseDuringDetail() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        await model.start()
        let barrier = FixtureBarrier(); await f.reader.holdMaterialize("source-0", barrier: barrier)
        model.send(.sourceTapped("source-0")); await barrier.entered()
        model.send(.sourceTapped("source-2"))
        await eventually { model.displayFile != nil }
        let displayed = try #require(model.displayFile), detail = try #require(model.detail)
        await barrier.release()
        #expect(model.state.viewedSourceID == "source-2")
        #expect(model.state.displayedVersion == .cameraJPEG)
        #expect(model.displayFile === displayed)
        model.send(.sourceTapped("source-1"))
        let result = try await detail(CGRect(x: 0, y: 0, width: 0.5, height: 0.5), 256)
        #expect(FileManager.default.fileExists(atPath: result.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: displayed.fileURL.path))
    }

    @Test func unknownSaveAndDeletedOutputNeverBecomeAllSavedOrResubmitted() async throws {
        let f = try await FixtureEnvironment.make(uncertain: true), model = AppModel(environment: f.environment)
        await model.start(); await model.connect()
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil }
        await model.export(); await eventually { model.exportEvent?.terminal == true }
        #expect(model.exportEvent?.summary.completed == 0)
        #expect(model.exportEvent?.summary.unresolved == 1)
        #expect(!f.platform.idleTimerDisabled)
        await model.reconcile(); await model.resumeExport(retry: true)
        #expect(await f.writer.requests.count == 1)
        #expect(model.exportEvent?.summary.unresolved == 1)
        #expect(!f.platform.idleTimerDisabled)
    }

    @Test func scopeNarrowingWhileSaveIsInFlightClassifiesOnlyActualCompletion() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment), barrier = FixtureBarrier()
        await model.start(); await model.connect()
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil }
        model.send(.select); model.send(.all(accessibleEligibleSourceIDs: []))
        await eventually { model.state.checkedSourceIDs.count == 3 }
        await f.writer.holdSave(barrier); await model.export(); await barrier.entered()
        await f.reader.restrictTo(["source-2"])
        let reload = Task { await model.reloadLibrary() }
        await eventually { model.sources.count == 1 }
        #expect(model.exportEvent?.summary.completed == 0)
        #expect(Set(model.sources.map(\.id)) == ["source-2"])
        await barrier.release(); await reload.value; await eventually { model.exportEvent?.terminal == true }
        #expect(model.exportEvent?.summary.completed == 1)
        #expect(model.exportEvent?.summary.unprocessed == 2)
        #expect(try await f.environment.catalog.versions(sourceID: "source-0").count == 1)
        #expect(await f.writer.requests.count == 1)
    }

    @Test func launchRoutingRejectsMixedModesAndIsolatesUnitHost() {
        #expect(FixtureEnvironment.route(arguments: ["--ui-fixtures", "--xt5-read-only-probe"], unitHost: false) == .invalid)
        #expect(FixtureEnvironment.route(arguments: ["--ui-fixtures", "--workspace-fixture"], unitHost: false) == .invalid)
        #expect(FixtureEnvironment.route(arguments: [], unitHost: true) == .unitHost)
        #expect(FixtureEnvironment.route(arguments: ["--ui-fixtures"], unitHost: false) == .flow)
        #expect(FixtureEnvironment.route(arguments: [], unitHost: false) == .live)
    }

    @Test func manualVersionSupersedesIntentWithoutCancellingActiveCameraOperation() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment), barrier = FixtureBarrier()
        await model.start(); await model.connect()
        await f.camera.holdRender(barrier)
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await barrier.entered()
        model.send(.versionSelected(.cameraJPEG))
        await eventually { model.displayFile != nil }
        let file = model.displayFile
        await barrier.release()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await f.camera.cancelledRenders == 0)
        #expect(model.state.displayedVersion == .cameraJPEG)
        #expect(model.displayFile === file)
        #expect(await f.writer.requests.isEmpty)
    }

    @Test func deletedOutputIsMarkedUnavailableWithoutRemovingItsVersionRecord() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        await model.start(); await model.connect()
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil }
        await model.export(); await eventually { model.savedVersions.count == 1 }
        let version = try #require(model.savedVersions.first)
        await f.reader.removeOutput(version.outputAssetID)
        await eventually { model.savedVersions.first?.availability == .inaccessible }
        #expect(model.savedVersions.first?.id == version.id)
        model.send(.versionSelected(.saved(version.id)))
        await eventually { model.imageStatus?.contains("unavailable") == true }
        #expect(model.displayFile == nil)
        #expect(await f.writer.requests.count == 1)
    }

    @Test func fastBackgroundForegroundBackgroundNeverReopensBeforeFinalForeground() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment), barrier = FixtureBarrier()
        await model.start(); await model.connect()
        await eventually { model.state.currentCameraExecutionContext != nil }
        await f.camera.holdDisconnect(barrier)
        let first = Task { await model.sceneChanged(.background) }
        await barrier.entered()
        let middle = Task { await model.sceneChanged(.active) }
        await Task.yield()
        let last = Task { await model.sceneChanged(.background) }
        await Task.yield(); await barrier.release()
        await first.value; await middle.value; await last.value
        #expect(await f.camera.connectCount == 1)
        #expect(model.isSuspended)
        await model.sceneChanged(.active)
        #expect(await f.camera.connectCount == 2)
        #expect(!model.isSuspended)
    }

    @Test func recoveryKeepsEveryUnfinishedFrozenJobActionableWithoutResubmitting() async throws {
        let f = try await FixtureEnvironment.make(uncertain: true), model = AppModel(environment: f.environment)
        await model.start(); await model.connect()
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil }
        await model.export(); await eventually { model.exportEvent?.terminal == true }
        let first = try #require(model.exportEvent)
        model.send(.recipeSelected(slot: 2))
        await eventually { model.displayFile != nil && model.state.displayedVersion == model.preview.map { .preview($0.key) } }
        await model.export(); await eventually { model.exportEvent?.terminal == true && model.exportEvent?.jobID != first.jobID }
        let second = try #require(model.exportEvent)
        await model.reconcile()
        await eventually { model.progressEvents.count == 2 }
        #expect(Set(model.progressEvents.map(\.jobID)) == [first.jobID, second.jobID])
        #expect(Set(model.progressEvents.map(\.recipeLabel)) == ["Mountain greens", "Warm shadows"])
        #expect(model.progressEvents.allSatisfy { $0.terminal && $0.summary.unresolved == 1 && $0.summary.completed == 0 })
        #expect(await f.writer.requests.count == 2)
    }

    @Test func savedOutputMissingBeforeObservationIsStillMarkedUnavailableOnSelection() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        await model.start(); await model.connect()
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil }
        await model.export(); await eventually { model.savedVersions.count == 1 }
        let version = try #require(model.savedVersions.first)
        await f.reader.removeOutput(version.outputAssetID, notify: false)
        model.send(.versionSelected(.saved(version.id)))
        await eventually { model.savedVersions.first?.availability == .inaccessible }
        #expect(model.savedVersions.first?.id == version.id)
        #expect(await f.writer.requests.count == 1)
    }

    @Test func inactiveSystemPresentationRestoresIdleWithoutPausingTheExport() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment), barrier = FixtureBarrier()
        await model.start(); await model.connect()
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil }
        let rawReads = await f.reader.rawReads
        model.send(.recipeSelected(slot: nil))
        await eventually { model.displayFile != nil && model.state.displayedVersion == .cameraJPEG }
        #expect(await f.reader.rawReads == rawReads)
        model.send(.recipeSelected(slot: 3)); await eventually { model.preview != nil && model.state.canExport }
        await f.writer.holdSave(barrier); await model.export(); await barrier.entered()
        #expect(f.platform.idleTimerDisabled)
        await model.sceneChanged(.inactive)
        #expect(!f.platform.idleTimerDisabled)
        #expect(!model.isSuspended)
        #expect(model.exportEvent?.stopRequested == false)
        await barrier.release(); await eventually { model.exportEvent?.terminal == true }
        #expect(model.exportEvent?.summary.completed == 1)
        #expect(await f.camera.disconnectCount == 0)
        #expect(!f.platform.idleTimerDisabled)
    }

    @Test(arguments: [false, true]) func sameSourceRevisionReplacesReadyOrHeldOriginalBytes(_ held: Bool) async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment), barrier = FixtureBarrier()
        await model.start()
        defer { Task { await barrier.release() } }
        if held { await f.reader.holdMaterialize("source-0", barrier: barrier) }
        model.send(.sourceTapped("source-0"))
        if held { await barrier.entered() } else { await eventually { model.displayFile != nil } }
        let old = model.displayFile
        let expected = try await f.reader.replaceOriginal("source-0", revision: "replacement-original")
        await model.reloadLibrary()
        await eventually { model.displayFile != nil && model.displayFile !== old }
        let replacement = try #require(model.displayFile)
        #expect(try Data(contentsOf: replacement.fileURL) == expected)
        #expect(model.state.displayedVersion == .cameraJPEG)
        #expect(model.state.selectedRecipe == nil)
        await barrier.release()
        await eventually { await f.reader.materializations == (held ? 1 : 2) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.displayFile === replacement)
        #expect(try Data(contentsOf: replacement.fileURL) == expected)
        #expect(await f.writer.requests.isEmpty)
    }

    @Test func recoverySnapshotSurvivesSlowConsumerBeyondProgressBufferAndRejectsOlderEvents() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment), barrier = FixtureBarrier()
        defer { Task { await barrier.release() } }
        await model.start(); await model.connect()
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil }
        await model.export(); await eventually { model.savedVersions.count == 1 && model.exportEvent?.terminal == true }
        let source = try #require(model.sources.first), recipes = model.state.recipes
        var jobs: [ExportJob] = []
        for i in 0..<96 {
            let job = ExportJob(id: UUID(), submittedAt: Date(timeIntervalSince1970: Double(i)), recipeSnapshot: recipes[i % 7],
                items: [ExportItem(source: source, operationID: UUID()), ExportItem(source: model.sources[1], operationID: UUID())], state: .queued)
            try await f.environment.catalog.saveJob(job); jobs.append(job)
        }
        await f.reader.holdResources(barrier)
        let recovery = Task { await model.reconcile() }
        await barrier.entered(); await recovery.value
        let expected = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.recipeSnapshot.name) })
        #expect(Dictionary(uniqueKeysWithValues: model.progressEvents.filter { expected[$0.jobID] != nil }.map { ($0.jobID, $0.recipeLabel) }) == expected)
        // Change every durable outcome while the terminal-event consumer remains held.
        for var job in jobs {
            job.items[0].state = .failed(.insufficientStorage); job.state = .failed
            try await f.environment.catalog.saveJob(job)
        }
        await model.reconcile()
        #expect(model.progressEvents.filter { expected[$0.jobID] != nil }.allSatisfy { $0.summary.failed == 1 && $0.terminal })
        await barrier.release()
        // A later real event is a FIFO drain marker. Earlier buffered recovery events cannot
        // replace the authoritative failed outcomes with their older queued summaries.
        let sentinel = try #require(jobs.last)
        await f.environment.exports.cancel(jobID: sentinel.id)
        await eventually { model.exportEvent?.jobID == sentinel.id && model.exportEvent?.stage == .cancelled }
        #expect(model.progressEvents.count == 96)
        #expect(model.progressEvents.filter { $0.jobID != sentinel.id }.allSatisfy { $0.summary.failed == 1 && $0.terminal })
        #expect(Dictionary(uniqueKeysWithValues: model.progressEvents.map { ($0.jobID, $0.recipeLabel) }) == expected)
        #expect(await f.writer.requests.count == 1)
        #expect(await f.camera.renderCount == 1)
    }

    @Test func canonicalFoundRecoveryRefreshesVisibleVersionsBeforeQueuedTerminalConsumption() async throws {
        let f = try await FixtureEnvironment.make(uncertain: true), catalog = HeldVersionCatalog(base: f.environment.catalog), barrier = FixtureBarrier()
        defer { Task { await barrier.release() } }
        let model = model(f.environment, catalog: catalog)
        await model.start(); await model.connect()
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil }
        // Hold the stream consumer's final version-list read after the unresolved terminal event.
        // The return value is captured BEFORE the barrier, so it cannot accidentally see recovery.
        await catalog.holdFinalVersionRead(barrier)
        await model.export(); await barrier.entered()
        let pending = try #require(model.exportEvent)
        #expect(pending.terminal && pending.summary.unresolved == 1)
        let request = try #require(await f.writer.requests.first)
        let asset = try await f.writer.makeSubmittedExportDiscoverable(request.operationID)
        await model.reconcile()
        #expect(model.exportEvent?.jobID == pending.jobID)
        #expect(model.exportEvent?.summary.completed == 1)
        #expect(model.exportEvent?.summary.unresolved == 0)
        #expect(try await f.environment.catalog.versions(sourceID: "source-0").count == 1)
        #expect(model.savedVersions.isEmpty)
        // No new user action, library change or worker event follows the canonical handoff.
        await barrier.release()
        await eventually { model.savedVersions.contains { $0.outputAssetID == asset.assetID && $0.operationID == request.operationID && $0.availability == .available } }
        #expect(await f.writer.requests.count == 1)
        #expect(await f.camera.renderCount == 1)
    }

    @Test func delayedVersionRefreshCannotRollbackAfterReturningToSameSource() async throws {
        let f = try await FixtureEnvironment.make(), catalog = HeldVersionCatalog(base: f.environment.catalog), barrier = FixtureBarrier()
        defer { Task { await barrier.release() } }
        let model = model(f.environment, catalog: catalog)
        await model.start(); await model.connect()
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil }
        await model.export(); await eventually { model.savedVersions.count == 1 && model.exportEvent?.terminal == true }
        let saved = try #require(model.savedVersions.first)
        model.send(.recipeSelected(slot: nil)); await eventually { model.displayFile != nil }
        await catalog.holdFinalVersionRead(barrier)
        let old = Task { await model.reloadLibrary() }
        await barrier.entered()
        model.send(.sourceTapped("source-2"))
        await eventually { model.displayFile != nil && model.savedVersions.isEmpty }
        await f.reader.removeOutput(saved.outputAssetID, notify: false)
        model.send(.sourceTapped("source-0"))
        await eventually { model.savedVersions.first?.availability == .inaccessible && model.displayFile != nil }
        let current = model.displayFile
        await barrier.release(); await old.value
        #expect(model.savedVersions.first?.id == saved.id)
        #expect(model.savedVersions.first?.availability == .inaccessible)
        #expect(model.displayFile === current)
        #expect(await f.writer.requests.count == 1)
    }

    private func model(_ environment: AppEnvironment, catalog: any CatalogStoring) -> AppModel {
        AppModel(environment: AppEnvironment(reader: environment.reader, camera: environment.camera, catalog: catalog,
            originals: environment.originals,
            preview: environment.preview, resolver: environment.resolver, exports: environment.exports,
            cache: environment.cache, thumbnails: environment.thumbnails, platform: environment.platform))
    }

    private func eventually(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var satisfied = false
        while ContinuousClock.now < deadline {
            if await condition() { satisfied = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(satisfied)
    }
}

/// Delegates to the same actual disk catalog; only the captured version-list return is delayed.
private actor HeldVersionCatalog: CatalogStoring {
    let base: any CatalogStoring
    private var barrier: FixtureBarrier?
    private var readsBeforeHold = 0
    init(base: any CatalogStoring) { self.base = base }
    func holdFinalVersionRead(_ barrier: FixtureBarrier) { self.barrier = barrier; readsBeforeHold = 1 }
    func versions(sourceID: SourceID) async throws -> [SavedVersion] {
        let result = try await base.versions(sourceID: sourceID)
        if let barrier {
            if readsBeforeHold > 0 { readsBeforeHold -= 1 }
            else { self.barrier = nil; await barrier.wait() }
        }
        return result
    }
    func upsertSources(_ sources: [PhotoSource]) async throws { try await base.upsertSources(sources) }
    func replaceRecipes(_ snapshots: [RecipeSnapshot]) async throws { try await base.replaceRecipes(snapshots) }
    func recipes(camera: CameraExecutionContext) async throws -> [RecipeSnapshot] { try await base.recipes(camera: camera) }
    func latestRecipes() async throws -> [RecipeSnapshot] { try await base.latestRecipes() }
    func saveJob(_ job: ExportJob) async throws { try await base.saveJob(job) }
    func job(id: UUID) async throws -> ExportJob { try await base.job(id: id) }
    func unfinishedJobs() async throws -> [ExportJob] { try await base.unfinishedJobs() }
    func confirmSaved(jobID: UUID, operationID: UUID, version: SavedVersion) async throws { try await base.confirmSaved(jobID: jobID, operationID: operationID, version: version) }
    func setAvailability(assetID: String, availability: AssetAvailability) async throws { try await base.setAvailability(assetID: assetID, availability: availability) }
}
