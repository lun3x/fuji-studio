@testable import FujiCameraCore
import SwiftUI
import Testing
@testable import FujiStudio

@MainActor struct AppModelTests {
    @Test func reenabledFilterRetriesUnavailablePhotosAndKeepsSuccessfulChecks() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        await model.start()
        await eventually { model.state.photoFilterCamera != nil && !model.isRefreshing }
        await f.reader.failMaterialize("source-0", error: .retrievalFailed("temporarily offline"))
        model.send(.photoFilterSelected(.compatibleWithCamera))
        await eventually { model.state.photoFilterPendingCount == 0 }
        #expect(model.state.photoFilterUnavailableCount == 1)
        #expect(await f.reader.rawReads == 2)
        await f.reader.failMaterialize("source-0", error: nil)
        model.send(.photoFilterSelected(.allPhotos)); model.send(.photoFilterSelected(.compatibleWithCamera))
        await eventually { model.state.photoFilterPendingCount == 0 }
        #expect(model.state.photoFilterUnavailableCount == 0)
        #expect(await f.reader.rawReads == 3)
    }

    @Test func cameraFilterChecksWithoutRenderingAndReusesAssessments() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        await model.start()
        await eventually { model.state.photoFilterCamera != nil && !model.isRefreshing }
        #expect(await f.reader.rawReads == 0)
        #expect(model.state.photoFilter == .allPhotos)
        model.send(.photoFilterSelected(.compatibleWithCamera))
        await eventually { model.state.photoFilterPendingCount == 0 }
        // Generic fixture geometry is deliberately outside the strict camera rules.
        #expect(model.state.visibleSourceIDs.isEmpty)
        #expect(await f.reader.rawReads == 3)
        #expect(await f.camera.renderCount == 0)
        #expect(await f.writer.requests.isEmpty)
        model.send(.photoFilterSelected(.allPhotos)); model.send(.photoFilterSelected(.compatibleWithCamera))
        await eventually { model.state.photoFilterPendingCount == 0 }
        #expect(await f.reader.rawReads == 3)
    }

    @Test func disabledFilterCancelsChecksAndRejectsLateOriginals() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment), barrier = FixtureBarrier()
        defer { Task { await barrier.release() } }
        await model.start()
        await eventually { model.state.photoFilterCamera != nil && !model.isRefreshing }
        await f.reader.holdMaterialize("source-0", barrier: barrier)
        model.send(.photoFilterSelected(.compatibleWithCamera)); await barrier.entered()
        model.send(.photoFilterSelected(.allPhotos)); await barrier.release()
        for _ in 0..<30 { await Task.yield() }
        #expect(model.state.visibleSourceIDs.count == 3)
        #expect(await f.reader.rawReads == 0)
        #expect(await f.camera.renderCount == 0)
    }

    @Test func failedFilterChecksAreVisibleAndBackgroundCancelsWork() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment), barrier = FixtureBarrier()
        defer { Task { await barrier.release() } }
        await model.start()
        await eventually { model.state.photoFilterCamera != nil && !model.isRefreshing }
        await f.reader.failMaterialize("source-0", error: .retrievalFailed("offline"))
        await f.reader.holdMaterialize("source-1", barrier: barrier)
        model.send(.photoFilterSelected(.compatibleWithCamera)); await barrier.entered()
        #expect(model.state.photoFilterUnavailableCount == 1)
        let background = Task { await model.sceneChanged(.background) }
        await eventually { model.isSuspended }
        await barrier.release(); await background.value
        #expect(model.state.photoFilter == .allPhotos)
        #expect(await f.reader.rawReads == 0)
    }

    @Test func failedRecipeCommitCanRetryWithoutPhysicalReconnect() async throws {
        let camera = try ReceiptCamera(), f = try await FixtureEnvironment.make(cameraOverride: camera)
        let catalog = HeldVersionCatalog(base: f.environment.catalog)
        let model = model(f.environment, catalog: catalog)
        await model.start(automaticallyConnect: false)
        let previous = model.state.recipes
        await catalog.failNextRecipeSave()
        await model.connect()
        await eventually { await camera.importCount == 1 && !model.isRefreshing }
        #expect(model.state.recipes == previous)
        #expect(try await catalog.latestRecipes() == previous)
        #expect(model.state.currentCameraExecutionContext == nil)
        #expect(model.state.cameraState == .disconnected)
        // The Connect action must recover using the same attached body. The real
        // service does not emit READY again while its existing context is live.
        await model.connect()
        await eventually { await camera.importCount == 2 && !model.isRefreshing }
        #expect(model.state.currentCameraExecutionContext?.generation == 3)
        #expect(model.state.recipes.allSatisfy { $0.cameraContext.model == "X-E3" })
        #expect(try await catalog.latestRecipes() == model.state.recipes)
        #expect(await camera.renderCount == 0)
        #expect(await f.writer.requests.isEmpty)
    }
    @Test func temporaryInactiveSceneDoesNotDiscardOwnedImport() async throws {
        let camera=try ReceiptCamera(),f=try await FixtureEnvironment.make(cameraOverride:camera)
        let catalog=HeldVersionCatalog(base:f.environment.catalog),barrier=FixtureBarrier()
        let model=model(f.environment,catalog:catalog)
        await model.start(automaticallyConnect:false)
        await catalog.holdRecipeSave(barrier);await model.connect();await barrier.entered()
        await model.sceneChanged(.inactive);await barrier.release()
        await eventually { !model.isRefreshing }
        #expect(model.state.recipes.allSatisfy { $0.cameraContext.model == "X-E3" })
        #expect(model.state.currentCameraExecutionContext?.generation == 3)
        #expect(await camera.importCount == 1)
    }
    @Test func secondRefreshSupersedesFirstWithoutRepeatingBackup() async throws {
        let camera=try ReceiptCamera(),f=try await FixtureEnvironment.make(cameraOverride:camera),barrier=FixtureBarrier()
        await camera.holdImport(barrier)
        let model=AppModel(environment:f.environment)
        await model.start(automaticallyConnect:false);await model.connect();await barrier.entered()
        var entered=false
        let newer=Task { entered=true;await model.refreshRecipes() }
        while !entered { await Task.yield() }
        await barrier.release();await newer.value
        await eventually { !model.isRefreshing && model.state.currentCameraExecutionContext?.generation == 3 }
        #expect(await camera.importCount == 1)
        #expect(model.state.recipes.allSatisfy { $0.cameraContext.model == "X-E3" && $0.cameraContext.sessionGeneration == 3 })
    }
    @Test func delayedCloseDuringOwnedImportCannotDiscardVerifiedReceipt() async throws {
        let camera=try ReceiptCamera(),f=try await FixtureEnvironment.make(cameraOverride:camera),barrier=FixtureBarrier()
        await camera.holdImport(barrier)
        let model=AppModel(environment:f.environment)
        await model.start(automaticallyConnect:false);await model.connect();await barrier.entered()
        await camera.delayedClosedEvent();await barrier.release()
        await eventually { !model.isRefreshing && model.state.currentCameraExecutionContext?.generation == 3 }
        #expect(await camera.importCount == 1)
        #expect(model.state.recipes.allSatisfy { $0.cameraContext.model == "X-E3" })
    }
    @Test func backgroundDuringReceiptCommitCannotPublishAfterLifecycleChanges() async throws {
        let camera=try ReceiptCamera(),f=try await FixtureEnvironment.make(cameraOverride:camera)
        let catalog=HeldVersionCatalog(base:f.environment.catalog),barrier=FixtureBarrier()
        let model=model(f.environment,catalog:catalog)
        await model.start(automaticallyConnect:false);let before=model.state.recipes
        await catalog.holdRecipeSave(barrier);await model.connect();await barrier.entered()
        await model.sceneChanged(.background)
        await barrier.release();await eventually { !model.isRefreshing }
        #expect(model.state.recipes == before)
        #expect(model.state.currentCameraExecutionContext == nil)
    }
    @Test func ownedReopenAdoptsReceiptExactlyOnce() async throws {
        let camera=try ReceiptCamera(),f=try await FixtureEnvironment.make(cameraOverride:camera)
        let model=AppModel(environment:f.environment)
        await model.start(automaticallyConnect:false);await model.connect()
        await eventually { model.state.currentCameraExecutionContext?.generation == 3 && !model.isRefreshing }
        #expect(model.state.recipes.count == 7)
        #expect(model.state.recipes.allSatisfy { $0.cameraContext.model == "X-E3" && $0.cameraContext.sessionGeneration == 3 })
        await camera.repeatFinalReady()
        for _ in 0..<30 { await Task.yield() }
        #expect(await camera.importCount == 1)
        #expect(try await f.environment.catalog.latestRecipes() == model.state.recipes)
    }
    @Test func detachDuringCatalogSaveCannotPublishOldContext() async throws {
        let camera=try ReceiptCamera(),f=try await FixtureEnvironment.make(cameraOverride:camera)
        let catalog=HeldVersionCatalog(base:f.environment.catalog),barrier=FixtureBarrier()
        let model=model(f.environment,catalog:catalog)
        await model.start(automaticallyConnect:false)
        let previous=model.state.recipes
        await catalog.holdRecipeSave(barrier);await model.connect();await barrier.entered()
        await camera.disconnect();await eventually { model.state.currentCameraExecutionContext == nil }
        await barrier.release();await eventually { !model.isRefreshing }
        #expect(model.state.recipes == previous)
        #expect(model.state.currentCameraExecutionContext == nil)
    }
    @Test func savingWhilePreviewIsPendingSupersedesItsDisplayIntent() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment), barrier = FixtureBarrier()
        defer { Task { await barrier.release() } }
        await model.start(automaticallyConnect: false); await model.connect()
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        let camera = try #require(model.state.recipes.first { $0.slot == 3 })
        #expect(await model.copyRecipeToPhone(id: camera.id))
        let original = try #require(model.state.phoneRecipes.first)
        model.send(.sourceTapped("source-0")); await eventually { model.displayFile != nil }
        await f.camera.holdRender(barrier)
        model.send(.phoneRecipeSelected(original.id)); await barrier.entered()
        var draft = PhoneRecipeDraft(recipe: original); draft.name = "Newest"; draft.setValue(.film(.provia), for: .film)
        try await model.updatePhoneRecipe(draft)
        #expect(!model.isLoadingPreview)
        #expect(model.state.displayedVersion == .cameraJPEG)
        await barrier.release()
        let updated = try #require(model.state.phoneRecipes.first)
        await eventually { model.preview?.settingsDigest == updated.snapshot.settingsDigest && !model.isLoadingPreview }
        #expect(model.state.selectedRecipe == updated.snapshot)
    }

    @Test func offlineEditIsDurableAndFailedUpdateRetainsExistingPreset() async throws {
        let f = try await FixtureEnvironment.make(), catalog = HeldVersionCatalog(base: f.environment.catalog)
        let model = model(f.environment, catalog: catalog)
        await model.start(automaticallyConnect: false)
        let camera = try #require(model.state.recipes.first { $0.slot == 3 })
        #expect(await model.copyRecipeToPhone(id: camera.id))
        let original = try #require(model.state.phoneRecipes.first)
        var draft = PhoneRecipeDraft(recipe: original); draft.name = "Offline edit"; draft.setValue(.film(.provia), for: .film)
        try await model.updatePhoneRecipe(draft)
        let updated = try #require(model.state.phoneRecipes.first)
        #expect(updated.id == original.id)
        #expect(updated.snapshot.name == "Offline edit")
        #expect(model.state.selectedRecipe == nil)
        #expect(try await f.environment.catalog.phoneRecipes() == [updated])
        await catalog.failPhoneUpdates()
        var failed = PhoneRecipeDraft(recipe: updated); failed.name = "Must not save"
        await #expect(throws: CatalogError.self) { try await model.updatePhoneRecipe(failed) }
        #expect(model.state.phoneRecipes == [updated])
        #expect(try await f.environment.catalog.phoneRecipes() == [updated])
        #expect(await f.writer.requests.isEmpty)
    }

    @Test func editingSelectedRecipeRefreshesPreviewAndKeepsPriorExportSnapshot() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        await model.start(automaticallyConnect: false); await model.connect()
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        let camera = try #require(model.state.recipes.first { $0.slot == 3 })
        #expect(await model.copyRecipeToPhone(id: camera.id))
        let original = try #require(model.state.phoneRecipes.first)
        model.send(.sourceTapped("source-0")); model.send(.phoneRecipeSelected(original.id))
        await eventually { model.preview != nil && model.state.canExport }
        await model.export(); await eventually { model.exportEvent?.terminal == true }
        let saved = try await f.environment.catalog.versions(sourceID: "source-0")
        var draft = PhoneRecipeDraft(recipe: original); draft.name = "Edited look"; draft.setValue(.film(.provia), for: .film)
        try await model.updatePhoneRecipe(draft)
        let updated = try #require(model.state.phoneRecipes.first)
        await eventually { model.preview?.settingsDigest == updated.snapshot.settingsDigest && !model.isLoadingPreview }
        #expect(model.state.selectedRecipe == updated.snapshot)
        #expect(updated.snapshot.settingsDigest != original.snapshot.settingsDigest)
        #expect(try await f.environment.catalog.versions(sourceID: "source-0") == saved)
        #expect(saved.first?.recipeSnapshot == original.snapshot)
    }

    @Test func deletingSelectedPhoneRecipeStopsPendingPreviewAndCannotPublishLateResult() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment), barrier = FixtureBarrier()
        defer { Task { await barrier.release() } }
        await model.start(automaticallyConnect: false)
        let original = try #require(model.state.recipes.first { $0.slot == 3 })
        #expect(await model.copyRecipeToPhone(id: original.id))
        let copy = try #require(model.state.phoneRecipes.first)
        await model.connect()
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        model.send(.sourceTapped("source-0"))
        await eventually { model.displayFile != nil }
        await f.camera.holdRender(barrier)
        model.send(.phoneRecipeSelected(copy.id))
        await barrier.entered()
        #expect(model.isLoadingPreview)
        #expect(await model.deletePhoneRecipe(id: copy.id))
        #expect(model.state.phoneRecipes.isEmpty)
        #expect(model.state.selectedRecipe == nil)
        #expect(!model.isLoadingPreview)
        #expect(try await f.environment.catalog.phoneRecipes().isEmpty)
        await barrier.release()
        let session = await f.camera.session
        await eventually { model.displayFile != nil && model.state.cameraState == .ready(session) }
        #expect(model.state.displayedVersion == .cameraJPEG)
        #expect(model.state.selectedRecipe == nil)
        #expect(model.preview == nil)
        #expect(await f.writer.requests.isEmpty)
    }

    @Test func failedPhoneDeletionKeepsRecipeAndSelection() async throws {
        let f = try await FixtureEnvironment.make(), catalog = HeldVersionCatalog(base: f.environment.catalog)
        let model = model(f.environment, catalog: catalog)
        await model.start(automaticallyConnect: false)
        let original = try #require(model.state.recipes.first { $0.slot == 3 })
        #expect(await model.copyRecipeToPhone(id: original.id))
        let copy = try #require(model.state.phoneRecipes.first)
        await model.connect()
        await eventually { model.state.currentCameraExecutionContext != nil }
        model.send(.phoneRecipeSelected(copy.id))
        await catalog.failPhoneDeletes()
        #expect(!(await model.deletePhoneRecipe(id: copy.id)))
        #expect(model.state.phoneRecipes == [copy])
        #expect(model.state.selectedRecipe == copy.snapshot)
        #expect(try await f.environment.catalog.phoneRecipes() == [copy])
        #expect(model.message != nil)
    }

    @Test func startupAutomaticallyConnectsAndImportsRecipesOnlyOnce() async throws {
        let f = try await FixtureEnvironment.make()
        let model = AppModel(environment: f.environment)
        await model.start(); await model.start()
        await eventually { model.state.currentCameraExecutionContext != nil && model.state.recipes.count == 7 && !model.isRefreshing }
        #expect(await f.camera.connectCount == 1)
        #expect(await f.camera.importCount == 1)
        #expect(model.message == nil)
        await model.sceneChanged(.background)
    }

    @Test func missingCameraRetriesAfterThreeSecondsWithoutAnErrorAndLeavesReadySessionAlone() async throws {
        let f = try await FixtureEnvironment.make(), retry = ManualConnectionRetry()
        await f.camera.setConnectionFailure(.transport(.timeout))
        let model = AppModel(environment: f.environment, connectionRetryWait: { try await retry.wait($0) })
        await model.start()
        await eventually { await retry.isWaiting }
        #expect(model.state.currentCameraExecutionContext == nil)
        #expect(model.message == nil)
        #expect(model.connectionError == nil)
        #expect(await f.camera.connectCount == 1)
        #expect(await retry.delays == [.seconds(3)])
        await f.camera.setConnectionFailure(nil)
        await retry.advance()
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        await eventually { await retry.isWaiting }
        await retry.advance()
        await eventually { await retry.delays.count == 3 }
        #expect(await f.camera.connectCount == 2)
        #expect(await f.camera.importCount == 1)
        await model.sceneChanged(.background)
    }

    @Test func inactiveStopsRetriesAndForegroundConnectsWithoutAnEarlierSuccessfulSession() async throws {
        let f = try await FixtureEnvironment.make(), retry = ManualConnectionRetry()
        await f.camera.setConnectionFailure(.transport(.notConnected))
        let model = AppModel(environment: f.environment, connectionRetryWait: { try await retry.wait($0) })
        await model.start()
        await eventually { await retry.isWaiting }
        await model.sceneChanged(.inactive)
        await retry.advance()
        await eventually { !(await retry.isWaiting) }
        #expect(await f.camera.connectCount == 1)
        await model.sceneChanged(.background)
        await f.camera.setConnectionFailure(nil)
        await model.sceneChanged(.active)
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        #expect(await f.camera.connectCount == 2)
        await model.sceneChanged(.background)
    }

    @Test func discoveryDoesNotOverlapAndCancellationPreventsLateConnection() async throws {
        let f = try await FixtureEnvironment.make(), barrier = FixtureBarrier(), retry = ManualConnectionRetry()
        await f.camera.holdConnect(barrier)
        let model = AppModel(environment: f.environment, connectionRetryWait: { try await retry.wait($0) })
        await model.start(); await barrier.entered()
        #expect(model.isConnecting)
        #expect(!(await retry.isWaiting))
        await model.connect()
        #expect(await f.camera.connectCount == 1)
        await model.sceneChanged(.inactive)
        await barrier.release()
        await eventually { !model.isConnecting }
        #expect(model.state.currentCameraExecutionContext == nil)
        #expect(model.connectionError == nil)
        #expect(!(await retry.isWaiting))
        await model.sceneChanged(.active)
        await eventually { model.state.currentCameraExecutionContext != nil }
        await model.sceneChanged(.background)
    }

    @Test func cameraAuthorizationDenialWaitsForForegroundBeforeTryingAgain() async throws {
        let f = try await FixtureEnvironment.make(), retry = ManualConnectionRetry()
        await f.camera.setConnectionFailure(.transport(.authorizationDenied))
        let model = AppModel(environment: f.environment, connectionRetryWait: { try await retry.wait($0) })
        await model.start()
        await eventually { model.state.cameraState == .authorizationDenied && !model.isConnecting }
        await eventually { await retry.isWaiting }
        await retry.advance()
        await eventually { await retry.delays.count == 2 }
        #expect(await f.camera.connectCount == 1)
        await model.sceneChanged(.inactive)
        await f.camera.setConnectionFailure(nil)
        await model.sceneChanged(.active)
        await eventually { model.state.currentCameraExecutionContext != nil }
        #expect(await f.camera.connectCount == 2)
        await model.sceneChanged(.background)
    }

    @Test func automaticDiscoveryStartsBeforePhotosDiscoveryFinishes() async throws {
        let f = try await FixtureEnvironment.make(), barrier = FixtureBarrier()
        await f.reader.holdDiscovery(barrier)
        let model = AppModel(environment: f.environment)
        let startup = Task { await model.start() }
        await barrier.entered()
        await eventually { model.state.currentCameraExecutionContext != nil }
        #expect(model.isLoadingLibrary)
        await barrier.release(); await startup.value
        await model.sceneChanged(.background)
    }

    @Test func copyingOfflinePersistsWithoutChangingSelectionAndReloadsOnRestart() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        await model.start(automaticallyConnect: false)
        model.send(.sourceTapped("source-0"))
        await eventually { model.displayFile != nil }
        let original = try #require(model.state.recipes.first)
        #expect(await model.copyRecipeToPhone(id: original.id))
        #expect(model.state.selectedRecipe == nil)
        #expect(model.state.displayedVersion == .cameraJPEG)
        #expect(model.state.phoneRecipes.count == 1)
        let copy = try #require(model.state.phoneRecipes.first)
        #expect(copy.snapshot.copiedFromRecipeID == original.id)
        #expect(await model.copyRecipeToPhone(id: original.id))
        #expect(model.state.phoneRecipes == [copy])
        let restarted = AppModel(environment: f.environment)
        await restarted.start(automaticallyConnect: false)
        #expect(restarted.state.phoneRecipes == [copy])
        #expect(await f.writer.requests.isEmpty)
        #expect(await f.camera.connectCount == 0)
    }

    @Test func failedPhoneSaveDoesNotPublishACopyOrChangeSelection() async throws {
        let f = try await FixtureEnvironment.make()
        let catalog = HeldVersionCatalog(base: f.environment.catalog)
        let model = model(f.environment, catalog: catalog)
        await model.start(automaticallyConnect: false)
        await catalog.failPhoneSaves()
        let original = try #require(model.state.recipes.first)
        #expect(!(await model.copyRecipeToPhone(id: original.id)))
        #expect(model.state.phoneRecipes.isEmpty)
        #expect(model.state.selectedRecipe == nil)
        #expect(model.message != nil)
        #expect(try await f.environment.catalog.phoneRecipes().isEmpty)
    }

    @Test func phoneRecipeRendersAndExportsFrozenCopyThroughCamera() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        await model.start(automaticallyConnect: false)
        let original = try #require(model.state.recipes.first { $0.slot == 3 })
        #expect(await model.copyRecipeToPhone(id: original.id))
        let copy = try #require(model.state.phoneRecipes.first)
        await model.connect()
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        model.send(.sourceTapped("source-0"))
        model.send(.phoneRecipeSelected(copy.id))
        await eventually { model.preview != nil && !model.isRefreshing }
        #expect(model.state.selectedRecipe == copy.snapshot)
        #expect(model.preview?.settingsDigest == copy.snapshot.settingsDigest)
        await model.export()
        await eventually { model.exportEvent?.terminal == true }
        let saved = try await f.environment.catalog.versions(sourceID: "source-0")
        #expect(saved.count == 1)
        #expect(saved.first?.recipeSnapshot == copy.snapshot)
        #expect(saved.first?.recipeSnapshot.copiedFromRecipeID == original.id)
        #expect(await model.deletePhoneRecipe(id: copy.id))
        #expect(model.state.selectedRecipe == nil)
        #expect(try await f.environment.catalog.versions(sourceID: "source-0") == saved)
    }

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

    @Test func selectAndCancelPreserveViewedPhotoWithoutRediscovery() async throws {
        let f = try await FixtureEnvironment.make()
        let model = AppModel(environment: f.environment)
        await model.start()
        model.send(.sourceTapped("source-0"))
        model.send(.select)
        #expect(model.state.isSelecting)
        #expect(model.state.checkedSourceIDs == ["source-0"])
        model.send(.checkedSourcesReplaced(["source-0", "source-1"]))
        model.send(.done)
        #expect(!model.state.isSelecting)
        #expect(model.state.checkedSourceIDs.isEmpty)
        #expect(model.state.viewedSourceID == "source-0")
        #expect(await f.reader.discoveryRequests == 1)
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

    @Test func deniedAndLimitedPhotosAccessStillAllowsAutomaticCameraConnection() async throws {
        let f = try await FixtureEnvironment.make(access: .denied), model = AppModel(environment: f.environment)
        await model.start()
        #expect(model.sources.isEmpty)
        #expect(model.state.libraryAccess == .denied)
        model.openSettings(); #expect(f.platform.settingsCalls == 1)
        await f.reader.setAccess(.limited)
        await model.reloadLibrary()
        #expect(model.sources.count == 3)
        model.managePhotos(); #expect(f.platform.manageCalls == 1)
        await eventually { model.state.currentCameraExecutionContext != nil }
        #expect(await f.camera.connectCount == 1)
    }

    @Test func scopeNarrowingAfterCompletedExportRetainsSavedVersion() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        await model.start(); await model.connect()
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
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
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
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
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil }
        model.send(.select); model.send(.checkedSourcesReplaced(["source-0", "source-1", "source-2"]))
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
        await eventually { await f.camera.connectCount == 2 }
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

    @Test func photoSelectionDuringForegroundReloadKeepsMatchingImageAndLoadsNewSelection() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment), barrier = FixtureBarrier()
        defer { Task { await barrier.release() } }
        await model.start()
        model.send(.sourceTapped("source-0"))
        await eventually { model.displayFile != nil }
        let original = try #require(model.displayFile)
        await model.sceneChanged(.background)
        await f.reader.holdDiscovery(barrier)
        let foreground = Task { await model.sceneChanged(.active) }
        await barrier.entered()

        model.send(.sourceTapped("source-0"))
        #expect(model.displayFile === original)
        model.send(.sourceTapped("source-2"))
        #expect(model.displayFile === original)
        #expect(model.imageLoading == .loading)
        #expect(!model.imageStatusIsFailure)

        await barrier.release(); await foreground.value
        await eventually { model.displayFile != nil && model.imageLoading == nil }
        #expect(model.state.viewedSourceID == "source-2")
        #expect(model.state.displayedVersion == .cameraJPEG)
        #expect(model.displayFile !== original)
        #expect(await f.camera.renderCount == 0)
        #expect(await f.writer.requests.isEmpty)
    }

    @Test func interruptedRecipeWaitsForOriginalWithoutReportingItUnavailable() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment), barrier = FixtureBarrier()
        defer { Task { await barrier.release() } }
        await model.start(); await model.connect()
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil }
        await model.sceneChanged(.background)
        #expect(model.state.selectedRecipe == nil)
        #expect(model.state.displayedVersion == .cameraJPEG)
        #expect(model.displayFile == nil)
        #expect(model.imageLoading == .loading)
        #expect(!model.imageStatusIsFailure)

        await f.reader.holdMaterialize("source-0", barrier: barrier)
        await model.sceneChanged(.active)
        await barrier.entered()
        #expect(model.imageLoading == .loading)
        await barrier.release()
        await eventually { model.displayFile != nil && model.imageLoading == nil }
        #expect(model.state.displayedVersion == .cameraJPEG)
        #expect(await f.camera.renderCount == 1)
        #expect(await f.writer.requests.isEmpty)
    }

    @Test func foregroundKeepsReadyOriginalWhileRefreshingItsBytes() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment), barrier = FixtureBarrier()
        defer { Task { await barrier.release() } }
        await model.start()
        model.send(.sourceTapped("source-0"))
        await eventually { model.displayFile != nil }
        let original = try #require(model.displayFile)
        await model.sceneChanged(.background)
        await f.reader.holdMaterialize("source-0", barrier: barrier)
        await model.sceneChanged(.active)
        await barrier.entered()
        #expect(model.displayFile === original)
        #expect(model.imageLoading == .loading)
        await barrier.release()
        await eventually { model.displayFile != nil && model.imageLoading == nil }
        #expect(model.state.displayedVersion == .cameraJPEG)
        #expect(await f.writer.requests.isEmpty)
    }

    @Test func originalInterruptedDuringLoadingStaysPendingThroughForegroundDiscovery() async throws {
        let f = try await FixtureEnvironment.make(), model = AppModel(environment: f.environment)
        let transfer = FixtureBarrier(), discovery = FixtureBarrier()
        defer { Task { await transfer.release(); await discovery.release() } }
        await model.start()
        await f.reader.holdMaterialize("source-0", barrier: transfer)
        model.send(.sourceTapped("source-0"))
        await transfer.entered()
        await model.sceneChanged(.background)
        await f.reader.holdDiscovery(discovery)
        let foreground = Task { await model.sceneChanged(.active) }
        await discovery.entered()
        #expect(model.displayFile == nil)
        #expect(model.imageLoading == .loading)
        #expect(!model.imageStatusIsFailure)
        await discovery.release(); await foreground.value; await transfer.release()
        await eventually { model.displayFile != nil && model.imageLoading == nil }
        #expect(model.state.viewedSourceID == "source-0")
        #expect(model.state.displayedVersion == .cameraJPEG)
        #expect(await f.camera.renderCount == 0)
        #expect(await f.writer.requests.isEmpty)
    }

    @Test func incrementalDiscoveryPrunesViewedSourceOnlyAfterCompletePass() async throws {
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
        #expect(model.state.viewedSourceID == nil)
        model.send(.select); model.send(.checkedSourcesReplaced(["source-0", "source-1", "source-2"]))
        #expect(model.sources.count == 1)
        #expect(model.state.checkedSourceIDs == ["source-0"])
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
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
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
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil }
        model.send(.select); model.send(.checkedSourcesReplaced(["source-0", "source-1", "source-2"]))
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
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
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
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
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
        await eventually { await f.camera.connectCount == 2 }
        #expect(await f.camera.connectCount == 2)
        #expect(!model.isSuspended)
    }

    @Test func recoveryKeepsEveryUnfinishedFrozenJobActionableWithoutResubmitting() async throws {
        let f = try await FixtureEnvironment.make(uncertain: true), model = AppModel(environment: f.environment)
        await model.start(); await model.connect()
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil }
        await model.export(); await eventually { model.exportEvent?.terminal == true }
        let first = try #require(model.exportEvent)
        model.send(.recipeSelected(slot: 2))
        await eventually { !model.isLoadingPreview && model.state.canExport && model.displayFile != nil && model.state.displayedVersion == model.preview.map { .preview($0.key) } }
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
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
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
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
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
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
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
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
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
        await eventually { model.state.currentCameraExecutionContext != nil && !model.isRefreshing }
        model.send(.sourceTapped("source-0")); model.send(.recipeSelected(slot: 3))
        await eventually { model.preview != nil }
        await model.export(); await eventually { model.savedVersions.count == 1 && model.exportEvent?.terminal == true }
        let saved = try #require(model.savedVersions.first)
        model.send(.recipeSelected(slot: nil)); await eventually { model.displayFile != nil }
        await catalog.holdFinalVersionRead(barrier)
        let old = Task { await model.reloadLibrary() }
        await barrier.entered()
        model.send(.sourceTapped("source-2"))
        await eventually { model.displayFile != nil && model.imageLoading == nil && model.savedVersions.isEmpty }
        await f.reader.removeOutput(saved.outputAssetID, notify: false)
        model.send(.sourceTapped("source-0"))
        await eventually { model.savedVersions.first?.availability == .inaccessible && model.displayFile != nil && model.imageLoading == nil }
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
    private var recipeSavesToFail = 0
    func failNextRecipeSave() { recipeSavesToFail += 1 }
    private var recipeSaveBarrier:FixtureBarrier?
    func holdRecipeSave(_ barrier:FixtureBarrier) { recipeSaveBarrier=barrier }
    private var phoneSavesFail = false
    private var phoneDeletesFail = false
    func failPhoneDeletes() { phoneDeletesFail = true }
    func deletePhoneRecipe(id: UUID) async throws {
        if phoneDeletesFail { throw CatalogError.durableFailure("Synthetic phone delete failure") }
        try await base.deletePhoneRecipe(id: id)
    }
    func failPhoneSaves() { phoneSavesFail = true }
    private var phoneUpdatesFail = false
    func failPhoneUpdates() { phoneUpdatesFail = true }
    func updatePhoneRecipe(_ draft: PhoneRecipeDraft) async throws -> PhoneRecipe {
        if phoneUpdatesFail { throw CatalogError.durableFailure("Synthetic edit failure") }
        return try await base.updatePhoneRecipe(draft)
    }
    func phoneRecipes() async throws -> [PhoneRecipe] { try await base.phoneRecipes() }
    func copyRecipeToPhone(_ recipe: RecipeSnapshot) async throws -> PhoneRecipe {
        if phoneSavesFail { throw CatalogError.durableFailure("Synthetic phone save failure") }
        return try await base.copyRecipeToPhone(recipe)
    }
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
    func replaceRecipes(_ snapshots: ImportedRecipeCollection) async throws {
        if recipeSavesToFail > 0 {
            recipeSavesToFail -= 1
            throw CatalogError.durableFailure("Synthetic recipe commit failure")
        }
        try await base.replaceRecipes(snapshots)
        if let barrier=recipeSaveBarrier { recipeSaveBarrier=nil;await barrier.wait() }
    }
    func latestRecipeSlots() async throws -> [RecipeSlot] { try await base.latestRecipeSlots() }
    func recipes(camera: CameraExecutionContext) async throws -> [RecipeSnapshot] { try await base.recipes(camera: camera) }
    func latestRecipes() async throws -> [RecipeSnapshot] { try await base.latestRecipes() }
    func saveJob(_ job: ExportJob) async throws { try await base.saveJob(job) }
    func job(id: UUID) async throws -> ExportJob { try await base.job(id: id) }
    func unfinishedJobs() async throws -> [ExportJob] { try await base.unfinishedJobs() }
    func confirmSaved(jobID: UUID, operationID: UUID, version: SavedVersion) async throws { try await base.confirmSaved(jobID: jobID, operationID: operationID, version: version) }
    func setAvailability(assetID: String, availability: AssetAvailability) async throws { try await base.setAvailability(assetID: assetID, availability: availability) }
}
