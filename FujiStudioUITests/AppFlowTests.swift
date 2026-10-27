import XCTest

@MainActor final class AppFlowTests: XCTestCase {
    private func launch(_ flags: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixtures"] + flags; app.launch()
        XCTAssertTrue(app.buttons["workspace.select"].waitForExistence(timeout: 10))
        return app
    }
    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        let rect = element.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.midX, dy: rect.midY)).tap()
    }
    private func recipe(_ slot: Int, in app: XCUIApplication) {
        tap(app.buttons["recipe.control"], in: app)
        XCTAssertTrue(app.buttons["recipe.slot.\(slot)"].waitForExistence(timeout: 5))
        tap(app.buttons["recipe.slot.\(slot)"], in: app)
    }
    private func clearRecipe(in app: XCUIApplication) {
        tap(app.buttons["recipe.control"], in: app)
        XCTAssertTrue(app.buttons["recipe.none"].waitForExistence(timeout: 5))
        tap(app.buttons["recipe.none"], in: app)
    }
    private func version(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        if app.buttons["workspace.versions"].exists { app.buttons["workspace.versions"].tap() }
        let button = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", identifier)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5)); return button
    }
    private func wait(_ condition: @escaping () -> Bool) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 10), .completed)
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let export = app.buttons["workspace.export"]
        let bounds = XCTAttachment(string: "Status \(app.buttons["app.status"].frame); Connect \(app.buttons["app.connect"].frame); Recipe \(app.buttons["recipe.control"].frame); Export \(export.exists ? String(describing: export.frame) : "hidden"); Grid \(app.collectionViews["photoGrid"].frame)")
        bounds.name = name + " bounds"; bounds.lifetime = .keepAlways; add(bounds)
    }
    private func selectFirstRow(_ app: XCUIApplication) {
        app.buttons["workspace.select"].tap()
        app.cells["grid.source-0"].tap() // Clear the viewed seed before an additive sweep.
        let start = app.cells["grid.source-0"].coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.65))
        let end = app.cells["grid.source-2"].coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.65))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
    func testRecipeSelectionReplacesVersionsWithExport() {
        let app = launch()
        app.cells["grid.source-0"].tap()
        let versions = app.buttons["workspace.versions"], export = app.buttons["workspace.export"]
        XCTAssertTrue(versions.waitForExistence(timeout: 5))
        XCTAssertFalse(export.exists)
        let versionFrame = versions.frame
        app.buttons["app.connect"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        XCTAssertFalse(export.exists)
        recipe(3, in: app)
        XCTAssertTrue(export.waitForExistence(timeout: 5))
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
        XCTAssertTrue(versions.waitForExistence(timeout: 5))
        XCTAssertFalse(export.exists)
        XCTAssertEqual(versions.frame, versionFrame)
        versions.tap()
        XCTAssertTrue(app.buttons["version.raw"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["version.cameraJPEG"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "version.saved.")).firstMatch.exists)
        XCTAssertFalse(app.buttons["version.preview"].exists)
        shot(app, "Clearing recipe restores original and saved versions")
    }
    func testExportStaysDisabledUntilPreviewFinishesDespiteCameraReadyUpdates() {
        let app = launch(["--fixture-held-preview"])
        app.cells["grid.source-0"].tap()
        app.buttons["app.connect"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(3, in: app)
        let export = app.buttons["workspace.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
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
    func testInjectedFlowOpensRealWorkspaceWithoutSystemPermissions() {
        let app = launch()
        XCTAssertTrue(app.buttons["app.connect"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
        app.cells["grid.source-0"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["workspace.export"].exists)
        shot(app, "Offline paired original")
    }
    func testPhotoChangeKeepsPreviousImageAndZoomUnderLoadingOverlay() {
        let app = launch(["--fixture-held-photo"])
        app.cells["grid.source-0"].tap()
        let viewer = app.scrollViews["viewer.image"], loading = app.descendants(matching: .any)["viewer.loading"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        wait { !loading.exists }
        viewer.pinch(withScale: 2, velocity: 1)
        func zoom() -> Double { Double((viewer.value as? String ?? "").split(separator: ",").first ?? "") ?? -1 }
        let frame = viewer.frame, previousZoom = zoom()
        XCTAssertGreaterThan(previousZoom, 1.1)
        app.cells["grid.source-2"].tap()
        XCTAssertTrue(loading.waitForExistence(timeout: 5))
        XCTAssertTrue(viewer.exists)
        XCTAssertEqual(viewer.frame, frame)
        XCTAssertEqual(zoom(), previousZoom, accuracy: 0.01)
        XCTAssertEqual(loading.frame.midX, frame.midX, accuracy: 1)
        XCTAssertEqual(loading.frame.midY, frame.midY, accuracy: 1)
        shot(app, "Previous photo greyed under photo-switch spinner")
        app.buttons["fixture.finishPhoto"].tap()
        wait { !loading.exists && abs(zoom() - 1) < 0.01 }
        XCTAssertFalse(app.descendants(matching: .any)["viewer.unavailable"].exists)
        shot(app, "New photo replaces previous photo at fit")
    }
    func testDisconnectedRecipeMenuSelectsNoneAndDisablesCachedRecipesAndRefresh() {
        let app = launch()
        tap(app.buttons["recipe.control"], in: app)
        let none = app.buttons["recipe.none"]
        XCTAssertTrue(none.waitForExistence(timeout: 5))
        XCTAssertTrue(none.isSelected)
        XCTAssertTrue(none.isEnabled)
        for slot in 1...7 {
            let option = app.buttons["recipe.slot.\(slot)"]
            XCTAssertTrue(option.exists)
            XCTAssertFalse(option.isEnabled)
            XCTAssertFalse(option.isSelected)
        }
        XCTAssertFalse(app.buttons["recipe.refresh"].isEnabled)
        shot(app, "Disconnected recipes are greyed out with No recipe selected")
        tap(none, in: app)
        app.buttons["app.connect"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["recipe.control"], in: app)
        XCTAssertTrue(none.waitForExistence(timeout: 5))
        XCTAssertTrue(none.isSelected)
        for slot in 1...7 { XCTAssertTrue(app.buttons["recipe.slot.\(slot)"].isEnabled) }
        XCTAssertTrue(app.buttons["recipe.refresh"].isEnabled)
    }
    private func assertSingleHeaderRow(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let status = app.buttons["app.status"], connect = app.buttons["app.connect"]
        for control in [status, connect] {
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, file: file, line: line)
            XCTAssertGreaterThanOrEqual(control.frame.width, 44, file: file, line: line)
            XCTAssertEqual(control.frame.midY, status.frame.midY, accuracy: 1, file: file, line: line)
            XCTAssertGreaterThanOrEqual(control.frame.minX, app.frame.minX, file: file, line: line)
            XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX, file: file, line: line)
        }
        XCTAssertLessThanOrEqual(status.frame.maxX, connect.frame.minX, file: file, line: line)
        XCTAssertFalse(app.buttons["workspace.export"].exists, file: file, line: line)
        XCTAssertFalse(app.staticTexts["Fuji Studio"].exists, file: file, line: line)
    }
    func testSingleHeaderRowGivesSpaceBackToPhotoAndKeepsStatusActions() {
        let app = launch()
        app.cells["grid.source-0"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout: 5))
        assertSingleHeaderRow(app)
        let bottom = max(app.buttons["app.status"].frame.maxY, app.buttons["app.connect"].frame.maxY)
        let viewer = app.scrollViews["viewer.image"]
        XCTAssertGreaterThanOrEqual(viewer.frame.minY, bottom)
        XCTAssertLessThanOrEqual(viewer.frame.minY - bottom, 12, "No empty title row should remain above the photo")
        XCTAssertTrue(app.buttons["app.status"].isHittable)
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.staticTexts["app.access"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["app.connect"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        assertSingleHeaderRow(app)
        shot(app, "Single status and connect header above photo")
    }
    func testFloatingVersionsMenuReclaimsPhotoSpaceAndSwitchesWithoutExport() {
        let app = launch()
        app.cells["grid.source-0"].tap()
        let viewer = app.scrollViews["viewer.image"], versions = app.buttons["workspace.versions"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        for id in ["viewer.zoomOut", "viewer.fit", "viewer.zoomIn"] { XCTAssertFalse(app.buttons[id].exists) }
        XCTAssertEqual(viewer.frame.maxY, app.buttons["drawer.toggle"].frame.minY, accuracy: 1, "The photo should reach the tray without reserved control rows")
        XCTAssertTrue(versions.exists)
        guard versions.exists else { return }
        XCTAssertGreaterThanOrEqual(versions.frame.minY, viewer.frame.minY - 0.5)
        XCTAssertLessThanOrEqual(versions.frame.maxY, viewer.frame.maxY)
        XCTAssertEqual(versions.frame.maxX, viewer.frame.maxX - 16, accuracy: 1)
        XCTAssertFalse(versions.frame.intersects(app.buttons["recipe.control"].frame))
        XCTAssertFalse(app.buttons["version.cameraJPEG"].exists, "Versions appear only in the menu")
        versions.tap()
        let raw = app.buttons["version.raw"], jpeg = app.buttons["version.cameraJPEG"]
        XCTAssertTrue(jpeg.waitForExistence(timeout: 5))
        XCTAssertTrue(jpeg.isSelected)
        XCTAssertGreaterThanOrEqual(jpeg.frame.minY, raw.frame.maxY)
        raw.tap()
        wait { versions.value as? String == "RAW" }
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        XCTAssertFalse(raw.exists)
        versions.tap(); app.buttons["version.cameraJPEG"].tap()
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        let before = versions.value as? String
        versions.tap()
        viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8)).tap()
        XCTAssertFalse(app.buttons["version.raw"].exists)
        XCTAssertEqual(versions.value as? String, before)
        XCTAssertFalse(app.buttons["workspace.export"].exists)
        shot(app, "Floating versions and photo without bottom controls")
    }
    func testFloatingSelectionEntersAndCancelsWithoutMovingPhotos() {
        let app = launch()
        let select = app.buttons["workspace.select"], grid = app.collectionViews["photoGrid"]
        XCTAssertFalse(app.buttons["workspace.all"].exists)
        XCTAssertFalse(app.buttons["workspace.none"].exists)
        XCTAssertFalse(app.staticTexts["workspace.count"].exists)
        XCTAssertEqual(select.label, "Select")
        XCTAssertGreaterThanOrEqual(select.frame.minY, grid.frame.minY)
        XCTAssertEqual(select.frame.maxX, grid.frame.maxX - 12, accuracy: 1)
        app.cells["grid.source-0"].tap()
        let frame = app.cells["grid.source-0"].frame
        select.tap()
        XCTAssertEqual(select.label, "Cancel selection")
        XCTAssertEqual(app.cells["grid.source-0"].frame, frame)
        XCTAssertTrue(app.cells["grid.source-0"].isSelected)
        app.cells["grid.source-1"].tap()
        XCTAssertEqual(app.staticTexts["workspace.count"].label, "2 selected")
        shot(app, "Photos-style floating cancel and checked photos")
        select.tap()
        XCTAssertEqual(select.label, "Select")
        XCTAssertEqual(app.cells["grid.source-0"].frame, frame)
        XCTAssertFalse(app.cells["grid.source-0"].isSelected)
        XCTAssertFalse(app.cells["grid.source-1"].isSelected)
        XCTAssertFalse(app.staticTexts["workspace.count"].exists)
        shot(app, "Photos-style floating Select in browse")
    }
    func testLargestTextVersionMenuScrollsToFullSavedLabel() {
        let app = launch(["--fixture-accessibility"])
        app.cells["grid.source-0"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout: 5))
        app.buttons["app.connect"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(1, in: app)
        wait { app.buttons["workspace.export"].isEnabled }
        tap(app.buttons["workspace.export"], in: app)
        wait { app.buttons["app.status"].label.contains("1 saved") }
        clearRecipe(in: app)
        let saved = version("version.saved.", in: app)
        let options = app.scrollViews["version.options"]
        for _ in 0..<12 {
            if saved.frame.minY >= options.frame.minY && saved.frame.maxY <= options.frame.maxY { break }
            let targetAbove = saved.frame.minY < options.frame.minY
            options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05,
                thenDragTo: options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: targetAbove ? 0.65 : 0.35)),
                withVelocity: 100, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(saved.label.contains("C1 Soft daylight"))
        XCTAssertFalse(saved.label.contains("Exported"))
        XCTAssertNotNil(saved.label.range(of: #"\d{2}/\d{2}/\d{2} \d{2}:\d{2}"#, options: .regularExpression))
        XCTAssertGreaterThan(saved.frame.height, app.buttons["version.raw"].frame.height, "The full saved label wraps")
        XCTAssertGreaterThanOrEqual(saved.frame.minY, options.frame.minY - 0.5)
        XCTAssertLessThanOrEqual(saved.frame.maxY, options.frame.maxY + 0.5)
        let label = saved.label
        let frames = XCTAttachment(string: "Saved row: \(saved.frame); menu viewport: \(options.frame)")
        frames.name = "Largest text saved version bounds"; frames.lifetime = .keepAlways; add(frames)
        shot(app, "Largest text versions menu with full saved label")
        tap(saved, in: app)
        XCTAssertEqual(app.buttons["workspace.versions"].value as? String, label)
        XCTAssertFalse(saved.exists)
        XCTAssertTrue(app.scrollViews["viewer.image"].exists)
    }
    func testPreviewDisconnectClearsRecipeAndDisablesMenuAtLargestText() {
        let app = launch(["--fixture-preview-failure", "--fixture-accessibility"])
        app.cells["grid.source-0"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout: 5))
        app.buttons["app.connect"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(1, in: app)
        wait { app.buttons["recipe.control"].label == "No recipe selected" }
        XCTAssertTrue(app.scrollViews["viewer.image"].exists)
        XCTAssertGreaterThan(app.scrollViews["viewer.image"].frame.height, 40)
        XCTAssertEqual(app.buttons["workspace.versions"].value as? String, "Original camera JPEG")
        XCTAssertFalse(app.buttons["workspace.export"].exists)
        tap(app.buttons["recipe.control"], in: app)
        XCTAssertTrue(app.buttons["recipe.none"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["recipe.none"].isSelected)
        XCTAssertTrue(app.buttons["recipe.none"].isEnabled)
        for slot in 1...7 { XCTAssertFalse(app.buttons["recipe.slot.\(slot)"].isEnabled) }
        XCTAssertFalse(app.buttons["recipe.refresh"].isEnabled)
        shot(app, "Disconnected recipe reset and disabled choices at AX5")
        tap(app.buttons["recipe.none"], in: app)
        XCTAssertTrue(app.scrollViews["viewer.image"].isHittable)
        for id in ["viewer.zoomOut", "viewer.fit", "viewer.zoomIn"] { XCTAssertFalse(app.buttons[id].exists) }
        let grid = app.collectionViews["photoGrid"], side = app.cells["grid.source-0"].frame.width
        XCTAssertGreaterThan(grid.frame.height, side)
        XCTAssertLessThan(grid.frame.height, side * 2)
        let frame = app.scrollViews["viewer.image"].frame
        app.buttons["drawer.toggle"].tap(); wait { app.buttons["drawer.toggle"].value as? String == "Expanded" }
        XCTAssertFalse(app.buttons["viewer.zoomIn"].exists)
        app.buttons["drawer.toggle"].tap(); wait { app.buttons["drawer.toggle"].value as? String == "Collapsed" }
        XCTAssertEqual(app.scrollViews["viewer.image"].frame, frame)
    }
    func testPairedC3PreviewSingleExportAndTrackedVersion() {
        let app = launch()
        app.cells["grid.source-0"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout: 5))
        app.buttons["app.connect"].tap()
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
        XCTAssertTrue(app.staticTexts["export.counts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["export.counts"].label.contains("1 saved"))
        XCTAssertEqual(app.staticTexts["export.status"].label, "Export saved")
        shot(app, "Single export tracked and saved")
    }
    func testMixedBatchKeepsFrozenC3WhileRecipeChangesAndClearsForManualVersion() {
        let app = launch(["--fixture-held-save", "--fixture-held-start"])
        wait { app.buttons["fixture.finishStart"].value as? String == "active" }
        app.buttons["fixture.finishStart"].tap()
        app.cells["grid.source-0"].tap(); app.buttons["app.connect"].tap()
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
        app.cells["grid.source-0"].tap(); app.buttons["app.connect"].tap()
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
    private func backgroundFlow(native: Bool) {
        let app = launch(["--fixture-held-save"] + (native ? [] : ["--fixture-scene-controls"]))
        app.cells["grid.source-0"].tap(); app.buttons["app.connect"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(3, in: app)
        selectFirstRow(app)
        wait { app.staticTexts["workspace.count"].label == "3 selected" }
        app.buttons["workspace.export"].tap()
        wait { app.buttons["app.status"].label.contains("Saving to Photos") }
        if native {
            XCUIDevice.shared.press(.home)
            let reachedBackground = app.wait(for: .runningBackground, timeout: 5)
            let boundary = XCTAttachment(string: "Reached background: \(reachedBackground), application state: \(app.state.rawValue), at \(Date.timeIntervalSinceReferenceDate)")
            boundary.name = "Public background boundary"; boundary.lifetime = .keepAlways; add(boundary)
            app.activate()
            shot(app, "Actual scene state after Home and activate")
            guard reachedBackground else { XCTFail("Home did not produce a background application state"); return }
        } else {
            app.buttons["fixture.background"].tap()
            app.buttons["fixture.foreground"].tap()
        }
        XCTAssertTrue(app.buttons["fixture.finishSave"].waitForExistence(timeout: 5))
        app.buttons["fixture.finishSave"].tap()
        wait { app.buttons["app.status"].label.contains("Export paused") }
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.staticTexts["export.counts"].label.contains("1 saved"))
        XCTAssertTrue(app.staticTexts["export.counts"].label.contains("2 remaining"))
        wait { app.buttons["export.resume"].isEnabled }
        shot(app, native ? "Paused after verified native background" : "Paused after injected scene callbacks")
        app.buttons["export.resume"].tap()
        wait { app.staticTexts["export.counts"].label.contains("3 saved") }
        XCTAssertEqual(app.staticTexts["export.status"].label, "Export saved")
    }
    func testAXPinchInspectionStaysSeparateFromEnabledRecipeVersionsAndExport() {
        let app = launch(["--fixture-accessibility", "--fixture-dark"])
        app.cells["grid.source-0"].tap(); app.buttons["app.connect"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(1, in: app)
        wait { app.buttons["workspace.export"].isEnabled }
        let viewer = app.scrollViews["viewer.image"], grid = app.collectionViews["photoGrid"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        func magnitude() -> Double { Double((viewer.value as? String ?? "").split(separator: ",").first ?? "") ?? -1 }
        func inspect(_ name: String) {
            let floating = ["recipe.control", "workspace.export"]
            for id in ["viewer.zoomOut", "viewer.fit", "viewer.zoomIn"] { XCTAssertFalse(app.buttons[id].exists) }
            for id in floating {
                XCTAssertTrue(app.buttons[id].exists)
                XCTAssertTrue(app.buttons[id].isEnabled)
            }
            XCTAssertFalse(app.buttons["workspace.versions"].exists)
            XCTAssertFalse(app.buttons["workspace.export"].frame.intersects(app.buttons["recipe.control"].frame))
            XCTAssertGreaterThanOrEqual(app.buttons["workspace.export"].frame.minY, viewer.frame.minY - 0.5)
            XCTAssertLessThanOrEqual(app.buttons["workspace.export"].frame.maxY, viewer.frame.maxY)
            let frames = XCTAttachment(string: floating.map { "\($0): \(app.buttons[$0].frame)" }.joined(separator: "\n") + "\nViewer: \(viewer.frame), Grid: \(grid.frame)")
            frames.name = name + " inspection frames"; frames.lifetime = .keepAlways; add(frames)
            viewer.pinch(withScale: 2.5, velocity: 1); wait { magnitude() > 1.5 }
            viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).doubleTap()
            wait { abs(magnitude() - 1) < 0.01 }
            XCTAssertTrue(app.buttons["recipe.control"].label.contains("C1"))
            XCTAssertFalse(app.buttons["app.status"].label.contains("saved"))
            XCTAssertTrue(app.buttons["workspace.export"].isEnabled)
            // Over letterboxing, XCTest's automatic hit-point lookup tries to
            // scroll the zoom view. Use the same screen taps as recipe selection
            // and verify the menus actually open and dismiss without an export.
            tap(app.buttons["recipe.control"], in: app)
            XCTAssertTrue(app.buttons["recipe.slot.1"].waitForExistence(timeout: 5))
            tap(app.buttons["app.status"], in: app)
            XCTAssertTrue(app.buttons["recipe.slot.1"].waitForNonExistence(timeout: 3))
            XCTAssertFalse(app.buttons["app.status"].label.contains("saved"))
            shot(app, name)
        }
        inspect("AX5 collapsed enabled export and pinch inspection")
        let frame = viewer.frame, side = app.cells["grid.source-0"].frame.width
        XCTAssertGreaterThan(grid.frame.height, side)
        XCTAssertLessThan(grid.frame.height, side * 2)
        app.buttons["workspace.select"].tap()
        XCTAssertEqual(app.cells["grid.source-0"].frame.width, side, accuracy: 0.5)
        app.buttons["drawer.toggle"].tap(); wait { app.buttons["drawer.toggle"].value as? String == "Expanded" }
        // The selectors remain above the expanded drawer; there is no zoom button row.
        for id in ["viewer.zoomOut", "viewer.fit", "viewer.zoomIn"] { XCTAssertFalse(app.buttons[id].exists) }
        shot(app, "AX5 expanded drawer intentionally covers inspection controls")
        app.buttons["drawer.toggle"].tap(); wait { app.buttons["drawer.toggle"].value as? String == "Collapsed" }
        XCTAssertEqual(viewer.frame, frame)
        XCTAssertEqual(app.cells["grid.source-0"].frame.width, side, accuracy: 0.5)
        XCTAssertGreaterThan(grid.frame.height, side)
        XCTAssertLessThan(grid.frame.height, side * 2)
        inspect("AX5 recollapsed pinch inspection remains operable without export")
        // Floating controls over letterboxing can report isHittable == false to XCTest.
        // Verify a real screen tap still exports the selected recipe after inspection.
        tap(app.buttons["workspace.export"], in: app)
        wait { app.buttons["app.status"].label.contains("1 saved") }
        XCTAssertFalse(app.buttons["workspace.versions"].exists)
    }

    func testAccessibleStatusAndConnectionControlsStayOutsideWorkspaceControls() {
        let app = launch(["--fixture-accessibility", "--fixture-limited", "--fixture-dark"])
        app.cells["grid.source-0"].tap()
        assertSingleHeaderRow(app)
        XCTAssertGreaterThanOrEqual(app.buttons["app.status"].frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["app.connect"].frame.height, 44)
        XCTAssertLessThanOrEqual(app.buttons["app.connect"].frame.height, app.buttons["app.status"].frame.height + 1)
        XCTAssertLessThanOrEqual(app.buttons["app.status"].frame.maxY, app.buttons["recipe.control"].frame.minY)
        app.buttons["drawer.toggle"].tap()
        wait { app.buttons["drawer.toggle"].value as? String == "Expanded" }
        let bottom = max(app.buttons["recipe.control"].frame.maxY, app.buttons["workspace.versions"].frame.maxY)
        XCTAssertGreaterThanOrEqual(app.buttons["drawer.toggle"].frame.minY, bottom)
        shot(app, "AX5 dark measured app controls and expanded drawer")
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.buttons["app.managePhotos"].waitForExistence(timeout: 5))
        shot(app, "AX5 scrollable status and limited-access management")
    }
}
