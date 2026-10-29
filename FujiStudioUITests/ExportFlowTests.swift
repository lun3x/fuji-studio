import XCTest

@MainActor
final class ExportFlowTests: AppFlowTestCase {
    func testRecipeSelectionReplacesVersionsWithExport() {
        let app = launch()
        app.cells["grid.source-0"].tap()
        let versions = app.buttons["workspace.versions"], export = app.buttons["workspace.export"]
        XCTAssertTrue(versions.waitUntilExists(timeout: 5))
        XCTAssertFalse(export.exists)
        let versionFrame = versions.frame
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        XCTAssertFalse(export.exists)
        recipe(3, in: app)
        XCTAssertTrue(export.waitUntilExists(timeout: 5))
        XCTAssertFalse(versions.exists)
        XCTAssertFalse(app.scrollViews["version.options"].exists)
        XCTAssertEqual(export.frame, versionFrame)
        wait { export.isEnabled }
        shot(app, "Recipe replaces version selector with floating export")
        export.tap()
        wait { app.buttons["app.status"].label.contains("1 saved") }
        XCTAssertFalse(versions.exists)
        tap(app.buttons["recipe.control"], in: app)
        tap(app.buttons["recipe.none"], in: app)
        XCTAssertTrue(versions.waitUntilExists(timeout: 5))
        XCTAssertFalse(export.exists)
        XCTAssertEqual(versions.frame, versionFrame)
        versions.tap()
        XCTAssertTrue(app.buttons["version.raw"].waitUntilExists(timeout: 5))
        XCTAssertTrue(app.buttons["version.cameraJPEG"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "version.saved.")).firstMatch.exists)
        XCTAssertFalse(app.buttons["version.preview"].exists)
        shot(app, "Clearing recipe restores original and saved versions")
    }

    func testExportStaysDisabledUntilPreviewFinishesDespiteCameraReadyUpdates() {
        let app = launch(["--fixture-held-preview"])
        app.cells["grid.source-0"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(3, in: app)
        let export = app.buttons["workspace.export"]
        XCTAssertTrue(export.waitUntilExists(timeout: 5))
        wait { app.buttons["fixture.finishPreview"].value as? String == "Loading preview" }
        XCTAssertFalse(export.isEnabled, "Export starts grey while the preview is being prepared")
        for _ in 0..<3 {
            app.buttons["fixture.cycleCamera"].tap()
            wait { app.buttons["app.status"].label.contains("Camera ready") }
            XCTAssertFalse(export.isEnabled, "A ready camera must not enable export before the preview is loaded")
        }
        shot(app, "Export stays grey while preview is loading")
        app.buttons["fixture.finishPreview"].tap()
        wait { export.isEnabled }
        XCTAssertTrue(app.scrollViews["viewer.image"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["viewer.status"].exists)
        shot(app, "Export becomes blue when preview is ready")
        tap(export, in: app)
        wait { app.buttons["app.status"].label.contains("1 saved") }
    }

    func testPairedC3PreviewSingleExportAndTrackedVersion() {
        let app = launch()
        app.cells["grid.source-0"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitUntilExists(timeout: 5))
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(3, in: app)
        wait { app.scrollViews["viewer.image"].exists && !app.descendants(matching: .any)["viewer.status"].exists }
        wait { app.buttons["workspace.export"].isEnabled }
        XCTAssertFalse(app.buttons["workspace.versions"].exists)
        shot(app, "C3 preview with floating export")
        app.buttons["workspace.export"].tap()
        wait { app.buttons["app.status"].label.contains("1 saved") }
        clearRecipe(in: app)
        let saved = version("version.saved.", in: app)
        XCTAssertTrue(saved.label.contains("C3 Mountain greens"))
        shot(app, "Saved version recipe title and compact date subtitle")
        saved.tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].exists)
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.staticTexts["export.counts"].waitUntilExists(timeout: 5))
        XCTAssertTrue(app.staticTexts["export.counts"].label.contains("1 saved"))
        XCTAssertEqual(app.staticTexts["export.status"].label, "Export saved")
        shot(app, "Single export tracked and saved")
    }

    func testMixedBatchKeepsFrozenC3WhileRecipeChangesAndClearsForManualVersion() {
        let app = launch(["--fixture-held-save", "--fixture-held-start"])
        wait { app.buttons["fixture.finishStart"].value as? String == "active" }
        app.buttons["fixture.finishStart"].tap()
        app.cells["grid.source-0"].tap(); wait { app.buttons["app.status"].label.contains("Camera ready") }
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(3, in: app)
        selectFirstRow(app)
        wait { app.staticTexts["workspace.count"].label == "3 selected" }
        app.buttons["workspace.export"].tap()
        wait { app.buttons["app.status"].label.contains("Saving to Photos") }
        XCTAssertEqual(app.buttons["fixture.finishSave"].value as? String, "Awake")
        recipe(2, in: app)
        XCTAssertTrue(app.buttons["recipe.control"].label.contains("C2"))
        XCTAssertFalse(app.buttons["workspace.versions"].exists)
        clearRecipe(in: app)
        version("version.cameraJPEG", in: app).tap()
        XCTAssertEqual(app.buttons["recipe.control"].label, "No recipe selected")
        XCTAssertEqual(app.staticTexts["workspace.count"].label, "3 selected")
        XCTAssertFalse(app.buttons["workspace.export"].exists)
        shot(app, "Frozen C3 batch after clearing recipe and viewing original")
        app.buttons["fixture.finishSave"].tap()
        wait { app.buttons["app.status"].label.contains("3 saved") }
        app.buttons["app.status"].tap()
        XCTAssertEqual(app.staticTexts["export.recipe"].label, "Mountain greens")
        XCTAssertTrue(app.staticTexts["export.counts"].label.contains("3 saved"))
        shot(app, "Mixed batch complete with frozen recipe")
    }

    func testLimitedDeniedAndUnknownSaveRemainActionable() {
        var app = launch(["--fixture-denied"])
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.buttons["Open Settings"].exists)
        shot(app, "Denied Photos access")
        app.terminate()
        app = launch(["--fixture-limited"])
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.buttons["app.managePhotos"].exists)
        shot(app, "Limited Photos access")
        app.terminate()
        app = launch(["--fixture-unknown-save"])
        app.cells["grid.source-0"].tap(); wait { app.buttons["app.status"].label.contains("Camera ready") }
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(3, in: app)
        wait { app.buttons["workspace.export"].isEnabled }
        app.buttons["workspace.export"].tap()
        wait { app.buttons["app.status"].label.contains("Save unconfirmed") }
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.staticTexts["export.counts"].label.contains("0 saved"))
        XCTAssertTrue(app.staticTexts["export.counts"].label.contains("1 unconfirmed"))
        XCTAssertTrue(app.buttons["export.reconcile"].exists)
        XCTAssertFalse(app.buttons["export.resume"].exists)
        app.buttons["export.reconcile"].tap()
        XCTAssertEqual(app.staticTexts["export.status"].label, "Save unconfirmed")
        shot(app, "Unknown Photos save retained")
    }

    func testInjectedScenePauseRequiresExplicitResumeAfterSaveClassification() { backgroundFlow(native: false) }

    func testNativeHomeBackgroundBoundary() throws {
        guard ProcessInfo.processInfo.environment["FUJI_STUDIO_NATIVE_LIFECYCLE"] == "1" else {
            throw XCTSkip("NOT VERIFIED: Duo Home did not reach XCUIApplication.runningBackground or deliver a background scene callback while a synthetic save was held. See task12-red-epoch-scene-boundary.xcresult. Enable FUJI_STUDIO_NATIVE_LIFECYCLE=1 on a validated lifecycle destination.")
        }
        backgroundFlow(native: true)
    }
}
