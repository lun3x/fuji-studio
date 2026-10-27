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

    @Test func scopeNarrowingDuringPreparationPreservesCompletedOutputs() async throws {
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
