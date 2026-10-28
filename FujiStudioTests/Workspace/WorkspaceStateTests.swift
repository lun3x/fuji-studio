@testable import FujiCameraCore
import Foundation
import Testing
@testable import FujiStudio

struct WorkspaceStateTests {
    @Test func editingSelectedPresetSupersedesPreviewWhileKeepingStablePresetIdentity() throws {
        let f = try WorkspaceFixture(), phone = f.recipes[2].copiedToPhone()
        var state = f.state(); state.reduce(.sourceTapped("viewed")); state.reduce(.phoneRecipesLoaded([phone]))
        let old = try #require(preview(in: state.reduce(.phoneRecipeSelected(phone.id))))
        var draft = PhoneRecipeDraft(recipe: phone); draft.name = "Edited"; draft.setValue(.film(.provia), for: .film)
        let updated = PhoneRecipe(id: phone.id, snapshot: try draft.makeSnapshot())
        let new = try #require(preview(in: state.reduce(.phoneRecipeUpdated(updated))))
        #expect(state.phoneRecipes == [updated])
        #expect(state.selectedRecipe == updated.snapshot)
        #expect(new.recipe == updated.snapshot)
        #expect(!state.acceptsPreview(old))
        state.reduce(.previewCompleted(request: old, key: f.key(old)))
        #expect(state.displayedVersion == .cameraJPEG)
        state.reduce(.previewCompleted(request: new, key: f.key(new)))
        #expect(state.displayedVersion == .preview(f.key(new)))
    }

    @Test func editingUnselectedPresetDoesNotSelectItAndCannotResurrectDeletedMembership() throws {
        let f = try WorkspaceFixture(), phone = f.recipes[2].copiedToPhone()
        var state = f.state(); state.reduce(.phoneRecipesLoaded([phone]))
        let selected = state.selectedRecipe
        var draft = PhoneRecipeDraft(recipe: phone); draft.name = "Other name"
        let updated = PhoneRecipe(id: phone.id, snapshot: try draft.makeSnapshot())
        #expect(state.reduce(.phoneRecipeUpdated(updated)).isEmpty)
        #expect(state.selectedRecipe == selected)
        state.reduce(.phoneRecipeDeleted(phone.id))
        #expect(state.reduce(.phoneRecipeUpdated(updated)).isEmpty)
        #expect(state.phoneRecipes.isEmpty)
    }

    @Test func phoneSelectionSurvivesCameraRefreshAndUsesIndependentIdentity() throws {
        let f = try WorkspaceFixture(), copy = f.recipes[2].copiedToPhone()
        var state = f.state()
        state.reduce(.sourceTapped("viewed"))
        state.reduce(.phoneRecipesLoaded([copy]))
        let request = try #require(preview(in: state.reduce(.phoneRecipeSelected(copy.id))))
        #expect(request.recipe == copy.snapshot)
        state.reduce(.previewCompleted(request: request, key: f.key(request)))
        #expect(state.reduce(.recipesRefreshed(try f.refreshedRecipes())).isEmpty)
        #expect(state.selectedRecipe == copy.snapshot)
        #expect(state.displayedVersion == .preview(f.key(request)))
        #expect(state.canExport)
        state.reduce(.recipeSelected(slot: 3))
        #expect(state.selectedRecipe?.isPhoneRecipe == false)
        state.reduce(.phoneRecipeSelected(UUID()))
        #expect(state.selectedRecipe?.isPhoneRecipe == false)
    }

    @Test func phoneSelectionRequiresConnectionAndDisconnectClearsItLikeCameraRecipes() throws {
        let f = try WorkspaceFixture(), copy = f.recipes[2].copiedToPhone()
        var state = WorkspaceState(sources: [f.source("viewed")], access: .full)
        state.reduce(.sourceTapped("viewed"))
        state.reduce(.phoneRecipesLoaded([copy]))
        #expect(state.reduce(.phoneRecipeSelected(copy.id)).isEmpty)
        #expect(state.selectedRecipe == nil)
        #expect(state.displayedVersion == .cameraJPEG)
        #expect(state.reduce(.cameraChanged(.ready(f.session), context: f.context)).isEmpty)
        let request = try #require(preview(in: state.reduce(.phoneRecipeSelected(copy.id))))
        #expect(request.recipe == copy.snapshot)
        state.reduce(.previewCompleted(request: request, key: f.key(request)))
        state.reduce(.cameraChanged(.disconnected, context: nil))
        #expect(state.selectedRecipe == nil)
        #expect(state.displayedVersion == .cameraJPEG)
        #expect(!state.canExport)
        #expect(state.reduce(.cameraChanged(.ready(f.session), context: f.context)).isEmpty)
        #expect(state.selectedRecipe == nil)
        let reconnect = try #require(preview(in: state.reduce(.phoneRecipeSelected(copy.id))))
        #expect(reconnect.recipe == copy.snapshot)
        let wrong = CameraExecutionContext(model: "X-T4", firmware: f.context.firmware,
            capability: f.context.capability, supportVersion: f.context.supportVersion, sessionIdentity: UUID(), generation: 1)
        #expect(state.reduce(.cameraChanged(.ready(f.session), context: wrong)).isEmpty)
        #expect(state.exportDisabledReason == .recipeCameraMismatch)
        state.reduce(.recipeSelected(slot: nil))
        #expect(state.selectedRecipe == nil)
    }

    @Test func deletingPhoneRecipeInvalidatesOnlyItsOwnSelectionAndPendingPreview() throws {
        let f = try WorkspaceFixture(), selected = f.recipes[2].copiedToPhone(), other = f.recipes[1].copiedToPhone()
        var state = f.state()
        state.reduce(.sourceTapped("viewed"))
        state.reduce(.phoneRecipesLoaded([selected, other]))
        let request = try #require(preview(in: state.reduce(.phoneRecipeSelected(selected.id))))
        #expect(state.reduce(.phoneRecipeDeleted(other.id)).isEmpty)
        #expect(state.selectedRecipe == selected.snapshot)
        #expect(state.acceptsPreview(request))
        #expect(state.phoneRecipes == [selected])
        state.reduce(.phoneRecipeDeleted(selected.id))
        #expect(state.phoneRecipes.isEmpty)
        #expect(state.selectedRecipe == nil)
        #expect(state.displayedVersion == .cameraJPEG)
        #expect(!state.acceptsPreview(request))
        state.reduce(.previewCompleted(request: request, key: f.key(request)))
        #expect(state.displayedVersion == .cameraJPEG)
    }

    @Test func unsupportedPhoneCopyCannotRequestPreviewOrExport() throws {
        let f = try WorkspaceFixture()
        let original = f.recipes[0]
        let unsupported = f.copy(original, digest: "invalid").copiedToPhone()
        var state = f.state()
        state.reduce(.sourceTapped("viewed"))
        state.reduce(.phoneRecipesLoaded([unsupported]))
        #expect(state.reduce(.phoneRecipeSelected(unsupported.id)).isEmpty)
        #expect(state.selectedRecipe == unsupported.snapshot)
        guard case .unsupportedRecipe = state.exportDisabledReason else { Issue.record("Unsupported copy became exportable"); return }
    }

    @Test func disconnectedCameraCannotSelectCachedRecipes() throws {
        let f = try WorkspaceFixture()
        var state = WorkspaceState(sources: [f.source("viewed")], access: .full)
        state.reduce(.sourceTapped("viewed"))
        state.reduce(.recipesRefreshed(f.recipes))
        for slot in 1...7 {
            #expect(state.reduce(.recipeSelected(slot: slot)).isEmpty)
            #expect(state.selectedRecipe == nil)
            #expect(state.displayedVersion == .cameraJPEG)
        }
        #expect(state.recipes == f.recipes)
    }

    @Test func disconnectClearsRecipeAndCompletedPreviewWithoutRestoringItOnReconnect() throws {
        let f = try WorkspaceFixture()
        for sourceID in ["viewed", "next"] {
            var state = f.state()
            let request = try #require(preview(in: state.reduce(.sourceTapped(sourceID))))
            state.reduce(.previewCompleted(request: request, key: f.key(request)))
            #expect(state.displayedVersion == .preview(f.key(request)))
            #expect(state.reduce(.cameraChanged(.disconnected, context: nil)).isEmpty)
            #expect(state.selectedRecipe == nil)
            #expect(state.displayedVersion == (sourceID == "viewed" ? .cameraJPEG : .raw))
            #expect(state.recipes == f.recipes)
            #expect(state.reduce(.cameraChanged(.ready(f.session), context: f.context)).isEmpty)
            #expect(state.selectedRecipe == nil)
        }
    }

    @Test func rangeReplacementOnlyChangesMembershipAndPrunesInaccessibleIDs() throws {
        let f = try WorkspaceFixture()
        var state = f.state()
        state.reduce(.sourceTapped("viewed")); state.reduce(.select)
        state.reduce(.drawerMoved(.expanded))
        let version = state.displayedVersion
        #expect(state.reduce(.checkedSourcesReplaced(["next", "missing"])).isEmpty)
        #expect(state.checkedSourceIDs == ["next"])
        #expect(state.viewedSourceID == "viewed")
        #expect(state.displayedVersion == version)
        #expect(state.drawerDetent == .expanded)
        state.reduce(.done)
        state.reduce(.checkedSourcesReplaced(["next"]))
        #expect(state.checkedSourceIDs.isEmpty)
    }
    @Test func browseExportsViewedPhotoWithoutEnteringSelect() throws {
        let f = try WorkspaceFixture()
        var state = f.state()
        state.reduce(.sourceTapped("viewed"))
        #expect(state.effectiveSourceIDs == ["viewed"])
        #expect(state.canExport)
        #expect(!state.isSelecting)
    }

    @Test func selectSeedsViewedThenTapTogglesAndViews() throws {
        let f = try WorkspaceFixture()
        var state = f.state()
        state.reduce(.sourceTapped("viewed"))
        state.reduce(.select)
        #expect(state.checkedSourceIDs == ["viewed"])
        state.reduce(.sourceTapped("next"))
        #expect(state.viewedSourceID == "next")
        #expect(state.checkedSourceIDs == ["viewed", "next"])
        state.reduce(.sourceTapped("next"))
        #expect(state.viewedSourceID == "next")
        #expect(state.checkedSourceIDs == ["viewed"])
    }

    @Test func emptySelectionDisablesExportAndCancelRestoresViewedSingleton() throws {
        let f = try WorkspaceFixture()
        var state = f.state()
        state.reduce(.sourceTapped("viewed"))
        state.reduce(.select)
        state.reduce(.checkedSourcesReplaced([]))
        #expect(state.isSelecting)
        #expect(state.effectiveSourceIDs.isEmpty)
        #expect(state.exportDisabledReason == .noSources)
        state.reduce(.done)
        #expect(!state.isSelecting)
        #expect(state.checkedSourceIDs.isEmpty)
        #expect(state.effectiveSourceIDs == ["viewed"])
        #expect(state.canExport)
    }

    @Test func rangeSelectionPrunesInaccessibleAndBlocksIncompatibleExport() throws {
        let f = try WorkspaceFixture()
        var state = f.state(sources: [f.source("viewed"), f.source("offscreen"), f.source("bad", compatibility: .incompatible(model: "X-T4"))])
        state.reduce(.sourceTapped("viewed"))
        state.reduce(.select)
        state.reduce(.checkedSourcesReplaced(["viewed", "offscreen", "bad", "missing"]))
        #expect(state.isSelecting)
        #expect(state.checkedSourceIDs == ["viewed", "offscreen", "bad"])
        #expect(state.effectiveSourceIDs == ["bad", "offscreen", "viewed"])
        #expect(state.exportDisabledReason == .incompatibleSource(sourceID: "bad", model: "X-T4"))
    }

    @Test func tappingPhotoNeverCollapsesExpandedDrawerInEitherMode() throws {
        let f = try WorkspaceFixture()
        for selecting in [false, true] {
            var state = f.state()
            state.reduce(.sourceTapped("viewed"))
            if selecting { state.reduce(.select) }
            state.reduce(.drawerMoved(.expanded))
            let effects = state.reduce(.sourceTapped("next"))
            #expect(state.drawerDetent == .expanded)
            let request = try #require(preview(in: effects))
            #expect(request.sourceID == "next")
            #expect(request.recipe.id == f.recipes[2].id)
            #expect(state.reduce(.drawerMoved(.collapsed)) == [.scrollToVisible(sourceID: "next")])
        }
    }

    @Test func manualVersionRetainsRecipeAndRejectsPendingPreview() throws {
        let f = try WorkspaceFixture()
        for version in [VersionID.raw, .cameraJPEG, .saved(UUID())] {
            var state = f.state()
            let request = try #require(preview(in: state.reduce(.sourceTapped("viewed"))))
            state.reduce(.versionSelected(version))
            state.reduce(.previewCompleted(request: request, key: f.key(request)))
            #expect(state.displayedVersion == version)
            #expect(state.selectedRecipe?.id == f.recipes[2].id)
            #expect(state.canExport)
        }
    }

    @Test func clearingRecipeChoosesPairedJPEGOrRAWAndRejectsOldPreview() throws {
        let f = try WorkspaceFixture()
        var state = f.state()
        let request = try #require(preview(in: state.reduce(.sourceTapped("viewed"))))
        state.reduce(.recipeSelected(slot: nil))
        state.reduce(.previewCompleted(request: request, key: f.key(request)))
        #expect(state.displayedVersion == .cameraJPEG)
        #expect(state.exportDisabledReason == .noRecipe)
        state.reduce(.sourceTapped("next"))
        #expect(state.displayedVersion == .raw)
    }

    @Test func onlyLatestSourceRecipeAndMatchingRenderKeyCanDisplayPreview() throws {
        let f = try WorkspaceFixture()
        var state = f.state()
        let oldSource = try #require(preview(in: state.reduce(.sourceTapped("viewed"))))
        let oldRecipe = try #require(preview(in: state.reduce(.sourceTapped("next"))))
        let latest = try #require(preview(in: state.reduce(.recipeSelected(slot: 4))))
        state.reduce(.previewCompleted(request: oldSource, key: f.key(oldSource)))
        state.reduce(.previewCompleted(request: oldRecipe, key: f.key(oldRecipe)))
        #expect(state.displayedVersion == .raw)
        state.reduce(.previewCompleted(request: latest, key: f.key(oldSource)))
        #expect(state.displayedVersion == .raw)
        let key = f.key(latest)
        state.reduce(.previewCompleted(request: latest, key: key))
        #expect(state.displayedVersion == .preview(key))
    }

    @Test func refreshedC3ChangesFutureTargetNotOldSnapshot() throws {
        let f = try WorkspaceFixture()
        var state = f.state()
        let old = try #require(preview(in: state.reduce(.sourceTapped("viewed"))))
        let original = f.recipes[2]
        let submittedJob = ExportJob(id: UUID(), submittedAt: Date(), recipeSnapshot: original,
            items: state.effectiveSources.map { ExportItem(source: $0, operationID: UUID()) }, state: .queued)
        let refreshed = try f.refreshedRecipes()
        let effects = state.reduce(.recipesRefreshed(refreshed))
        let new = try #require(preview(in: effects))
        #expect(state.selectedRecipe?.id == refreshed[2].id)
        #expect(state.selectedRecipe?.name == original.name)
        #expect(new.recipe.settingsDigest != old.recipe.settingsDigest)
        #expect(new.generation != old.generation)
        state.reduce(.previewCompleted(request: old, key: f.key(old)))
        #expect(state.displayedVersion == .cameraJPEG)
        #expect(submittedJob.recipeSnapshot.id == original.id)
        #expect(submittedJob.items.map(\.source.id) == ["viewed"])
    }

    @Test func failedOrMalformedRefreshPreservesAllSevenSlotsAndSelectedSnapshot() throws {
        let f = try WorkspaceFixture()
        var state = f.state()
        state.reduce(.sourceTapped("viewed"))
        let old = state.recipes
        state.reduce(.recipeRefreshFailed("USB disconnected"))
        #expect(state.recipes == old)
        #expect(state.recipeRefreshState == .stale("USB disconnected"))
        #expect(state.selectedRecipe?.id == old[2].id)
        for invalid in [Array(old.prefix(6)), Array(repeating: old[0], count: 7)] {
            #expect(state.reduce(.recipesRefreshed(invalid)).isEmpty)
            #expect(state.recipes == old)
            #expect(state.selectedRecipe?.id == old[2].id)
            if case .stale = state.recipeRefreshState {} else { Issue.record("Invalid refresh must be stale") }
        }
        state.reduce(.recipesRefreshed(try f.refreshedRecipes()))
        #expect(state.recipeRefreshState == .fresh)
    }

    @Test func exportRequiresSourcesRecipeReadyContextAndNoActiveJob() throws {
        let f = try WorkspaceFixture()
        var state = f.state()
        #expect(state.exportDisabledReason == .noSources)
        state.reduce(.sourceTapped("viewed"))
        state.reduce(.recipeSelected(slot: nil))
        #expect(state.exportDisabledReason == .noRecipe)
        state.reduce(.recipeSelected(slot: 3))
        state.reduce(.cameraChanged(.disconnected, context: nil))
        #expect(state.exportDisabledReason == .noRecipe)
        state.reduce(.cameraChanged(.ready(f.session), context: nil))
        state.reduce(.recipeSelected(slot: 3))
        #expect(state.exportDisabledReason == .cameraContextUnavailable)
        state.reduce(.cameraChanged(.ready(f.session), context: f.context))
        #expect(state.canExport)
        state.reduce(.activeJobChanged(UUID()))
        state.reduce(.cameraChanged(.busy(f.session), context: f.context))
        #expect(state.exportDisabledReason == .activeJob)
        #expect(state.eligibleSourceIDs == ["viewed", "next"])
        state.reduce(.activeJobChanged(nil))
        #expect(state.exportDisabledReason == .cameraNotReady)
        state.reduce(.cameraChanged(.ready(f.session), context: f.context))
        #expect(state.canExport)
    }

    @Test func incompatibleCheckedSourceHasReasonButUncheckedSourceDoesNotBlockExport() throws {
        let f = try WorkspaceFixture()
        var state = f.state(sources: [f.source("viewed"), f.source("bad", compatibility: .incompatible(model: "X-T4"))])
        state.reduce(.sourceTapped("bad"))
        #expect(state.exportDisabledReason == .incompatibleSource(sourceID: "bad", model: "X-T4"))
        state.reduce(.select)
        state.reduce(.sourceTapped("viewed"))
        #expect(!state.canExport)
        state.reduce(.sourceTapped("bad")) // Uncheck but continue viewing it.
        #expect(state.viewedSourceID == "bad")
        #expect(state.effectiveSourceIDs == ["viewed"])
        #expect(state.canExport)
    }

    @Test func unsupportedRecipeIsBrowseableWithDisabledReason() throws {
        let f = try WorkspaceFixture()
        var state = f.state()
        state.reduce(.sourceTapped("viewed"))
        var recipes = f.recipes
        recipes[2] = f.copy(recipes[2], settings: [], digest: "unsupported")
        #expect(state.reduce(.recipesRefreshed(recipes)).isEmpty)
        #expect(state.selectedRecipe?.id == recipes[2].id)
        #expect(state.exportDisabledReason == .unsupportedRecipe([.unsupportedMeasuredDomain]))
        #expect(state.exportDisabledReason?.message.isEmpty == false)
    }

    @Test func sourceRemovalAndLimitedAccessPreserveUnrelatedCheckedAndFrozenJob() throws {
        let f = try WorkspaceFixture()
        var state = f.state()
        state.reduce(.sourceTapped("viewed"))
        state.reduce(.select); state.reduce(.checkedSourcesReplaced(["viewed", "next"]))
        let frozen = ExportJob(id: UUID(), submittedAt: Date(), recipeSnapshot: f.recipes[2],
            items: state.effectiveSources.map { ExportItem(source: $0, operationID: UUID()) }, state: .queued)
        state.reduce(.libraryUpdated(sources: [f.source("next")], access: .limited))
        #expect(state.viewedSourceID == nil)
        #expect(state.displayedVersion == nil)
        #expect(state.checkedSourceIDs == ["next"])
        #expect(state.effectiveSourceIDs == ["next"])
        #expect(frozen.items.map(\.source.id) == ["next", "viewed"])
        state.reduce(.libraryUpdated(sources: [f.source("next")], access: .denied))
        #expect(state.checkedSourceIDs.isEmpty)
        #expect(state.effectiveSourceIDs.isEmpty)
        #expect(!state.canExport)
    }

    @Test func sourceRevisionChangeInvalidatesPreviewAndCompatibilityChangeDisablesExport() throws {
        let f = try WorkspaceFixture()
        var state = f.state()
        let request = try #require(preview(in: state.reduce(.sourceTapped("viewed"))))
        let changed = f.source("viewed", revision: "changed", compatibility: .incompatible(model: "X-T4"))
        state.reduce(.libraryUpdated(sources: [changed], access: .full))
        state.reduce(.previewCompleted(request: request, key: f.key(request)))
        #expect(state.displayedVersion == .cameraJPEG)
        #expect(state.exportDisabledReason == .incompatibleSource(sourceID: "viewed", model: "X-T4"))
    }

    @Test func disconnectRejectsPendingPreviewAndReconnectPreservesManualVersion() throws {
        let f = try WorkspaceFixture()
        var state = f.state()
        let old = try #require(preview(in: state.reduce(.sourceTapped("viewed"))))
        state.reduce(.cameraChanged(.disconnected, context: nil))
        #expect(state.selectedRecipe == nil)
        state.reduce(.previewCompleted(request: old, key: f.key(old)))
        #expect(state.displayedVersion == .cameraJPEG)
        let saved = VersionID.saved(UUID())
        state.reduce(.versionSelected(saved))
        #expect(state.reduce(.cameraChanged(.ready(f.session), context: f.context)).isEmpty)
        #expect(state.displayedVersion == saved)
        #expect(state.exportDisabledReason == .noRecipe)
    }

    @Test func compatibleReconnectRequiresExplicitRecipeSelectionAfterFailedRefreshAndRejectsOldContext() throws {
        let f = try WorkspaceFixture()
        var state = f.state()
        let old = try #require(preview(in: state.reduce(.sourceTapped("viewed"))))
        state.reduce(.cameraChanged(.disconnected, context: nil))
        let reconnected = CameraExecutionContext(model: f.context.model, firmware: f.context.firmware,
            capability: f.context.capability, supportVersion: f.context.supportVersion,
            sessionIdentity: UUID(), generation: 2)
        let session = CameraSession(generation: 2, connection: f.session.connection)
        state.reduce(.recipeRefreshFailed("Synthetic refresh failure"))
        #expect(state.reduce(.cameraChanged(.ready(session), context: reconnected)).isEmpty)
        #expect(state.exportDisabledReason == .noRecipe)
        #expect(state.selectedRecipe == nil)
        #expect(state.recipes == f.recipes)
        #expect(state.recipeRefreshState == .stale("Synthetic refresh failure"))
        let effects = state.reduce(.recipeSelected(slot: 3))
        #expect(state.canExport)
        let latest = try #require(preview(in: effects))
        #expect(latest.cameraContext == reconnected)
        #expect(latest.recipe.cameraContext == old.recipe.cameraContext)
        state.reduce(.previewCompleted(request: old, key: f.key(old)))
        #expect(state.displayedVersion == .cameraJPEG)
        state.reduce(.previewCompleted(request: latest, key: f.key(latest)))
        #expect(state.displayedVersion == .preview(f.key(latest)))
    }

    @Test func incompatibleReconnectStillRequiresSupportedCameraAndMatchingNativeGeneration() throws {
        let f = try WorkspaceFixture()
        for (model, firmware, capability, support) in [
            ("X-T4", f.context.firmware, f.context.capability, f.context.supportVersion),
            (f.context.model, "wrong", f.context.capability, f.context.supportVersion),
            (f.context.model, f.context.firmware, "wrong", f.context.supportVersion),
            (f.context.model, f.context.firmware, f.context.capability, "wrong")
        ] {
            var state = f.state()
            state.reduce(.sourceTapped("viewed"))
            let context = CameraExecutionContext(model: model, firmware: firmware, capability: capability,
                supportVersion: support, sessionIdentity: UUID(), generation: 1)
            #expect(state.reduce(.cameraChanged(.ready(f.session), context: context)).isEmpty)
            #expect(state.exportDisabledReason == .recipeCameraMismatch)
        }
        var state = f.state()
        state.reduce(.sourceTapped("viewed"))
        let wrongGeneration = CameraExecutionContext(model: f.context.model, firmware: f.context.firmware,
            capability: f.context.capability, supportVersion: f.context.supportVersion,
            sessionIdentity: UUID(), generation: 2)
        #expect(state.reduce(.cameraChanged(.ready(f.session), context: wrongGeneration)).isEmpty)
        #expect(state.exportDisabledReason == .cameraContextUnavailable)
    }

    @Test func ownBusyReadyCyclePreservesPreviewWithEitherCompletionOrderAndNeverRequeuesIt() throws {
        let f = try WorkspaceFixture()
        for completionBeforeReady in [false, true] {
            var state = f.state()
            let request = try #require(preview(in: state.reduce(.sourceTapped("viewed"))))
            #expect(state.reduce(.cameraChanged(.busy(f.session), context: f.context)).isEmpty)
            #expect(state.exportDisabledReason == .cameraNotReady)
            if completionBeforeReady {
                state.reduce(.previewCompleted(request: request, key: f.key(request)))
                #expect(state.displayedVersion == .preview(f.key(request)))
            }
            #expect(state.reduce(.cameraChanged(.ready(f.session), context: f.context)).isEmpty)
            if !completionBeforeReady {
                state.reduce(.previewCompleted(request: request, key: f.key(request)))
            }
            #expect(state.displayedVersion == .preview(f.key(request)))
            #expect(state.canExport)
            #expect(state.reduce(.cameraChanged(.busy(f.session), context: f.context)).isEmpty)
            #expect(state.reduce(.cameraChanged(.ready(f.session), context: f.context)).isEmpty)
            #expect(state.displayedVersion == .preview(f.key(request)))
        }
    }

    @Test func sourceIntentChangedWhileBusySupersedesOldPreviewAndRequestsLatestOnceReady() throws {
        let f = try WorkspaceFixture()
        var state = f.state()
        let old = try #require(preview(in: state.reduce(.sourceTapped("viewed"))))
        state.reduce(.cameraChanged(.busy(f.session), context: f.context))
        #expect(state.reduce(.sourceTapped("next")).isEmpty)
        state.reduce(.previewCompleted(request: old, key: f.key(old)))
        #expect(state.displayedVersion == .raw)
        let latest = try #require(preview(in: state.reduce(.cameraChanged(.ready(f.session), context: f.context))))
        #expect(latest.sourceID == "next")
        #expect(latest.generation > old.generation)
        state.reduce(.cameraChanged(.busy(f.session), context: f.context))
        state.reduce(.previewCompleted(request: latest, key: f.key(latest)))
        #expect(state.reduce(.cameraChanged(.ready(f.session), context: f.context)).isEmpty)
        #expect(state.displayedVersion == .preview(f.key(latest)))
    }

    @Test func recipeIntentChangedWhileBusySupersedesOldPreviewAndRequestsLatestOnceReady() throws {
        let f = try WorkspaceFixture()
        var state = f.state()
        let old = try #require(preview(in: state.reduce(.sourceTapped("viewed"))))
        state.reduce(.cameraChanged(.busy(f.session), context: f.context))
        #expect(state.reduce(.recipeSelected(slot: 4)).isEmpty)
        state.reduce(.previewCompleted(request: old, key: f.key(old)))
        #expect(state.displayedVersion == .cameraJPEG)
        let latest = try #require(preview(in: state.reduce(.cameraChanged(.ready(f.session), context: f.context))))
        #expect(latest.recipe.id == f.recipes[3].id)
        state.reduce(.cameraChanged(.busy(f.session), context: f.context))
        #expect(state.reduce(.cameraChanged(.ready(f.session), context: f.context)).isEmpty)
        state.reduce(.previewCompleted(request: latest, key: f.key(latest)))
        #expect(state.displayedVersion == .preview(f.key(latest)))
    }

    @Test func manualVersionChosenWhileBusyRejectsOldPreviewWithoutRequestWhenReady() throws {
        let f = try WorkspaceFixture()
        var state = f.state()
        let old = try #require(preview(in: state.reduce(.sourceTapped("viewed"))))
        state.reduce(.cameraChanged(.busy(f.session), context: f.context))
        state.reduce(.versionSelected(.raw))
        state.reduce(.previewCompleted(request: old, key: f.key(old)))
        #expect(state.reduce(.cameraChanged(.ready(f.session), context: f.context)).isEmpty)
        #expect(state.displayedVersion == .raw)
        #expect(state.selectedRecipe == f.recipes[2])
    }

    @Test func repeatedSameSourceRequestRejectsOlderGeneration() throws {
        let f = try WorkspaceFixture()
        var state = f.state()
        let old = try #require(preview(in: state.reduce(.sourceTapped("viewed"))))
        let latest = try #require(preview(in: state.reduce(.sourceTapped("viewed"))))
        #expect(latest.generation > old.generation)
        state.reduce(.previewCompleted(request: old, key: f.key(old)))
        #expect(state.displayedVersion == .cameraJPEG)
        state.reduce(.previewCompleted(request: latest, key: f.key(latest)))
        #expect(state.displayedVersion == .preview(f.key(latest)))
    }

    @Test func renderKeyMustMatchRequestedRevisionSettingsAndCameraContext() throws {
        let f = try WorkspaceFixture()
        var state = f.state()
        let request = try #require(preview(in: state.reduce(.sourceTapped("viewed"))))
        let other = CameraExecutionContext(model: f.context.model, firmware: f.context.firmware,
            capability: f.context.capability, supportVersion: f.context.supportVersion,
            sessionIdentity: UUID(), generation: f.context.generation)
        for (revision, digest, camera) in [
            ("wrong-revision", request.recipe.settingsDigest, request.cameraContext),
            (request.sourceRevision, "wrong-settings", request.cameraContext),
            (request.sourceRevision, request.recipe.settingsDigest, other)
        ] {
            let wrong = RenderKey(sourceID: request.sourceID, sourceRevision: revision, sourceSHA256: "synthetic-hash",
                settingsDigest: digest, cameraContext: camera, width: 7728, height: 5152, orientation: 1,
                policy: .fullSizeFineRecordedGeometry, quality: .fullResolutionFine)
            state.reduce(.previewCompleted(request: request, key: wrong))
            #expect(state.displayedVersion == .cameraJPEG)
        }
        state.reduce(.previewCompleted(request: request, key: f.key(request)))
        #expect(state.displayedVersion == .preview(f.key(request)))
    }

    @Test func accessDeniedAtInitializationRejectsInaccessibleTapAndSelection() throws {
        let f = try WorkspaceFixture()
        var state = WorkspaceState(sources: [f.source("viewed")], access: .denied)
        #expect(state.reduce(.sourceTapped("viewed")).isEmpty)
        state.reduce(.select); state.reduce(.checkedSourcesReplaced(["viewed"]))
        #expect(state.viewedSourceID == nil)
        #expect(state.displayedVersion == nil)
        #expect(state.effectiveSourceIDs.isEmpty)
        #expect(state.eligibleSourceIDs.isEmpty)
    }

    @Test func effectiveSourcesSortNewestFirstThenIDWithNilDatesLast() throws {
        let f = try WorkspaceFixture()
        var state = f.state(sources: [f.source("z", date: nil), f.source("b", date: 20),
            f.source("a", date: 20), f.source("old", date: 10), f.source("y", date: nil)])
        state.reduce(.select); state.reduce(.checkedSourcesReplaced(["z", "b", "a", "old", "y"]))
        #expect(state.effectiveSourceIDs == ["a", "b", "old", "y", "z"])
        #expect(state.effectiveSources.map(\.id) == ["a", "b", "old", "y", "z"])
    }

    private func preview(in effects: [WorkspaceEffect]) -> WorkspacePreviewRequest? {
        effects.compactMap { if case .requestPreview(let request) = $0 { request } else { nil } }.first
    }
}

private struct WorkspaceFixture {
    let recipes: [RecipeSnapshot]
    let context: CameraExecutionContext
    let session = CameraSession(generation: 1, connection: .init(name: "Synthetic X-T5", usbVendorID: 1, usbProductID: 2))
    init() throws {
        let profile = try ProductionProfileFixture()
        let banks = try (1...7).map { try BatchFixture().bank(slot: $0, properties: profile.properties) }
        let common = banks[0].cameraContext
        recipes = banks.map { RecipeSnapshot(id: $0.id, slot: $0.slot, name: $0.name, importedName: $0.importedName,
            importedSettings: $0.importedSettings, settingsDigest: $0.settingsDigest, cameraContext: common,
            importedAt: $0.importedAt, renderingIssues: $0.renderingIssues) }
        let camera = recipes[0].cameraContext
        context = CameraExecutionContext(model: camera.model, firmware: camera.firmware, capability: camera.capability,
            supportVersion: XT5WorkingProfile.supportVersion, sessionIdentity: camera.sessionIdentity, generation: camera.sessionGeneration)
    }
    func source(_ id: String, date: TimeInterval? = 100, revision: String = "v1", compatibility: RAWCompatibility = .unknown) -> PhotoSource {
        PhotoSource(id: id, originalResources: .init(raf: .init(assetID: id, role: .primaryOriginal,
            contentTypeIdentifier: "com.fujifilm.raw-image", format: .raf, originalFilename: "SYNTHETIC.RAF", discriminator: "raf"),
            jpeg: id == "viewed" ? .init(assetID: id, role: .alternateOriginal, contentTypeIdentifier: "public.jpeg",
                format: .jpeg, originalFilename: "SYNTHETIC.JPG", discriminator: "jpeg") : nil),
            captureDate: date.map(Date.init(timeIntervalSince1970:)), location: nil, resourceRevision: revision, compatibility: compatibility)
    }
    func state(sources: [PhotoSource]? = nil) -> WorkspaceState {
        var state = WorkspaceState(sources: sources ?? [source("viewed"), source("next")], access: .full)
        state.reduce(.recipesRefreshed(recipes))
        state.reduce(.cameraChanged(.ready(session), context: context))
        state.reduce(.recipeSelected(slot: 3))
        return state
    }
    func copy(_ recipe: RecipeSnapshot, settings: [ImportedRecipeProperty]? = nil, digest: String? = nil) -> RecipeSnapshot {
        RecipeSnapshot(id: UUID(), slot: recipe.slot, name: recipe.name, importedName: recipe.importedName,
            importedSettings: settings ?? recipe.importedSettings, settingsDigest: digest ?? recipe.settingsDigest,
            cameraContext: recipes[0].cameraContext, importedAt: recipe.importedAt, renderingIssues: [])
    }
    func refreshedRecipes() throws -> [RecipeSnapshot] {
        let profile = try ProductionProfileFixture()
        var properties = profile.properties
        properties[0xD192] = 1
        let changed = try BatchFixture().bank(slot: 3, properties: properties)
        return recipes.map { copy($0, settings: $0.slot == 3 ? changed.importedSettings : nil,
            digest: $0.slot == 3 ? changed.settingsDigest : nil) }
    }
    func key(_ request: WorkspacePreviewRequest) -> RenderKey {
        RenderKey(sourceID: request.sourceID, sourceRevision: request.sourceRevision, sourceSHA256: "synthetic-hash",
            settingsDigest: request.recipe.settingsDigest, cameraContext: request.cameraContext,
            width: 7728, height: 5152, orientation: 1, policy: .fullSizeFineRecordedGeometry, quality: .fullResolutionFine)
    }
}
