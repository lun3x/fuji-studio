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
        let bounds = XCTAttachment(string: "Status \(app.buttons["app.status"].frame); Connect \(app.buttons["app.connect"].frame); Recipe \(app.buttons["recipe.control"].frame); Export \(app.buttons["workspace.export"].frame); Grid \(app.collectionViews["photoGrid"].frame)")
        bounds.name = name + " bounds"; bounds.lifetime = .keepAlways; add(bounds)
    }
    func testInjectedFlowOpensRealWorkspaceWithoutSystemPermissions() {
        let app = launch()
        XCTAssertTrue(app.buttons["app.connect"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
        app.cells["grid.source-0"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["workspace.export"].isEnabled)
        shot(app, "Offline paired original")
    }
    func testAllDirectlyFromBrowseEntersSelectWithCompleteMembership() {
        let app = launch()
        XCTAssertEqual(app.buttons["workspace.select"].label, "Select")
        XCTAssertFalse(app.buttons["workspace.none"].isEnabled)
        XCTAssertTrue(app.buttons["workspace.all"].isEnabled)
        app.buttons["workspace.all"].tap()
        wait { app.staticTexts["workspace.count"].label == "3 selected" }
        XCTAssertEqual(app.buttons["workspace.select"].label, "Done")
        XCTAssertTrue(app.buttons["workspace.none"].isEnabled)
        for id in ["source-0", "source-1", "source-2"] {
            XCTAssertTrue(app.cells["grid.\(id)"].isSelected)
        }
    }
    func testFailedPreviewKeepsLabelledImageAndMeasuredAccessibleError() {
        let app = launch(["--fixture-preview-failure", "--fixture-accessibility"])
        app.cells["grid.source-0"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout: 5))
        app.buttons["app.connect"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(1, in: app)
        let status = app.buttons["viewer.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        wait { status.label.contains("Reconnect") }
        XCTAssertTrue(app.scrollViews["viewer.image"].exists)
        XCTAssertGreaterThan(app.scrollViews["viewer.image"].frame.height, 40)
        XCTAssertEqual(app.buttons["workspace.versions"].value as? String, "Original camera JPEG")
        XCTAssertTrue(app.buttons["recipe.control"].label.contains("C1"))
        shot(app, "Labelled original and actionable preview error at AX5")
        let bounds = XCTAttachment(string: "Status: \(status.frame); Viewer: \(app.scrollViews["viewer.image"].frame); Fit: \(app.buttons["viewer.fit"].frame)")
        bounds.name = "Preview error measured reservation"; bounds.lifetime = .keepAlways; add(bounds)
        for id in ["recipe.control", "workspace.versions", "workspace.export", "viewer.zoomIn", "viewer.fit"] {
            XCTAssertFalse(status.frame.intersects(app.buttons[id].frame), id)
        }
        XCTAssertTrue(status.isHittable)
        let fullMessage = status.label
        status.tap()
        XCTAssertTrue(app.staticTexts["viewer.status.details"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["viewer.status.details"].label, fullMessage)
        XCTAssertTrue(fullMessage.contains("Reconnect to reconcile before starting more work"))
        app.buttons["viewer.status.done"].tap()
        XCTAssertTrue(app.buttons["viewer.fit"].isHittable)
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
        let preview = version("version.preview", in: app)
        XCTAssertTrue(preview.isSelected)
        preview.tap()
        XCTAssertTrue(app.buttons["workspace.export"].isEnabled)
        shot(app, "C3 temporary preview")
        app.buttons["workspace.export"].tap()
        wait { app.buttons["app.status"].label.contains("1 saved") }
        let saved = version("version.saved.", in: app)
        XCTAssertTrue(saved.label.contains("C3 Mountain greens")); saved.tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].exists)
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.staticTexts["export.counts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["export.counts"].label.contains("1 saved"))
        XCTAssertEqual(app.staticTexts["export.status"].label, "Export saved")
        shot(app, "Single export tracked and saved")
    }
    func testMixedBatchKeepsFrozenC3WhileUIRecipeAndManualVersionChange() {
        let app = launch(["--fixture-held-save", "--fixture-held-start"])
        wait { app.buttons["fixture.finishStart"].value as? String == "active" }
        app.buttons["fixture.finishStart"].tap()
        app.cells["grid.source-0"].tap(); app.buttons["app.connect"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(3, in: app)
        version("version.preview", in: app).tap()
        app.buttons["workspace.select"].tap(); app.buttons["workspace.all"].tap()
        wait { app.staticTexts["workspace.count"].label == "3 selected" }
        app.buttons["workspace.export"].tap()
        wait { app.buttons["app.status"].label.contains("Saving to Photos") }
        XCTAssertEqual(app.buttons["fixture.finishSave"].value as? String, "Awake")
        recipe(2, in: app)
        version("version.cameraJPEG", in: app).tap()
        XCTAssertTrue(app.buttons["recipe.control"].label.contains("C2"))
        XCTAssertEqual(app.staticTexts["workspace.count"].label, "3 selected")
        XCTAssertFalse(app.buttons["workspace.export"].isEnabled)
        shot(app, "Frozen C3 batch with C2 and manual original")
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
        recipe(3, in: app); version("version.preview", in: app).tap()
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
        recipe(3, in: app); version("version.preview", in: app).tap()
        app.buttons["workspace.select"].tap(); app.buttons["workspace.all"].tap()
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
    func testAXInspectionActionsStaySeparateFromEnabledRecipeVersionsAndExport() {
        let app = launch(["--fixture-accessibility", "--fixture-dark"])
        app.cells["grid.source-0"].tap(); app.buttons["app.connect"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(1, in: app)
        version("version.preview", in: app).tap()
        XCTAssertTrue(app.buttons["workspace.export"].isEnabled)
        let viewer = app.scrollViews["viewer.image"], grid = app.collectionViews["photoGrid"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        func magnitude() -> Double { Double((viewer.value as? String ?? "").split(separator: ",").first ?? "") ?? -1 }
        func inspect(_ name: String) {
            let controls = ["viewer.zoomOut", "viewer.fit", "viewer.zoomIn"]
            let floating = ["recipe.control", "workspace.versions", "workspace.export"]
            for id in controls {
                XCTAssertTrue(app.buttons[id].isHittable)
                for other in floating { XCTAssertFalse(app.buttons[id].frame.intersects(app.buttons[other].frame), "\(id) intersects \(other)") }
            }
            let frames = XCTAttachment(string: (controls + floating).map { "\($0): \(app.buttons[$0].frame)" }.joined(separator: "\n") + "\nViewer: \(viewer.frame), Grid: \(grid.frame)")
            frames.name = name + " inspection frames"; frames.lifetime = .keepAlways; add(frames)
            tap(app.buttons["viewer.zoomIn"], in: app); wait { magnitude() > 1.5 }
            tap(app.buttons["viewer.zoomOut"], in: app); wait { abs(magnitude() - 1) < 0.01 }
            tap(app.buttons["viewer.zoomIn"], in: app); wait { magnitude() > 1.5 }
            tap(app.buttons["viewer.fit"], in: app); wait { abs(magnitude() - 1) < 0.01 }
            XCTAssertTrue(app.buttons["recipe.control"].label.contains("C1"))
            XCTAssertFalse(app.buttons["app.status"].label.contains("saved"))
            XCTAssertTrue(app.buttons["workspace.export"].isEnabled)
            shot(app, name)
        }
        inspect("AX5 collapsed enabled export and actual inspection actions")
        let frame = viewer.frame, side = app.cells["grid.source-0"].frame.width
        XCTAssertGreaterThan(grid.frame.height, side)
        XCTAssertLessThan(grid.frame.height, side * 2)
        app.buttons["workspace.select"].tap()
        XCTAssertEqual(app.cells["grid.source-0"].frame.width, side, accuracy: 0.5)
        app.buttons["drawer.toggle"].tap(); wait { app.buttons["drawer.toggle"].value as? String == "Expanded" }
        // Expanded drawer intentionally covers the viewer. Covered controls must not remain
        // separate hit/accessibility targets; exposed controls would require the same tap checks.
        for id in ["viewer.zoomOut", "viewer.fit", "viewer.zoomIn"] { XCTAssertFalse(app.buttons[id].exists) }
        shot(app, "AX5 expanded drawer intentionally covers inspection controls")
        app.buttons["drawer.toggle"].tap(); wait { app.buttons["drawer.toggle"].value as? String == "Collapsed" }
        XCTAssertEqual(viewer.frame, frame)
        XCTAssertEqual(app.cells["grid.source-0"].frame.width, side, accuracy: 0.5)
        XCTAssertGreaterThan(grid.frame.height, side)
        XCTAssertLessThan(grid.frame.height, side * 2)
        inspect("AX5 recollapsed inspection remains operable without export")
    }

    func testAccessibleStatusAndConnectionControlsStayOutsideWorkspaceControls() {
        let app = launch(["--fixture-accessibility", "--fixture-limited", "--fixture-dark"])
        app.cells["grid.source-0"].tap()
        XCTAssertGreaterThanOrEqual(app.buttons["app.status"].frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["app.connect"].frame.height, 44)
        XCTAssertLessThanOrEqual(app.buttons["app.connect"].frame.height, app.buttons["app.status"].frame.height + 1)
        XCTAssertLessThanOrEqual(app.buttons["app.status"].frame.maxY, app.buttons["recipe.control"].frame.minY)
        app.buttons["drawer.toggle"].tap()
        wait { app.buttons["drawer.toggle"].value as? String == "Expanded" }
        let bottom = max(app.buttons["recipe.control"].frame.maxY, app.buttons["workspace.export"].frame.maxY)
        XCTAssertGreaterThanOrEqual(app.buttons["drawer.toggle"].frame.minY, bottom)
        shot(app, "AX5 dark measured app controls and expanded drawer")
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.buttons["app.managePhotos"].waitForExistence(timeout: 5))
        shot(app, "AX5 scrollable status and limited-access management")
    }
}
