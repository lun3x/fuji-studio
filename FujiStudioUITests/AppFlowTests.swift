import XCTest

@MainActor
final class AppFlowTests: AppFlowTestCase {
    func testInjectedFlowOpensRealWorkspaceWithoutSystemPermissions() {
        let app = launch()
        XCTAssertFalse(app.buttons["app.connect"].exists)
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
        app.cells["grid.source-0"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["workspace.export"].exists)
        shot(app, "Automatically connected paired original")
    }

    func testInitiallyInactiveStartupWaitsForForegroundBeforeConnecting() {
        let app = launch(["--fixture-initial-inactive", "--fixture-scene-controls"])
        XCTAssertFalse(app.buttons["app.connect"].exists)
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.staticTexts["app.camera"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["app.camera"].label.contains("Plug in a supported Fujifilm camera"), app.staticTexts["app.camera"].label)
        app.buttons["Done"].tap()
        app.buttons["fixture.foreground"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
    }

    func testCameraIndicatorStaysPreparingThroughoutRecipeImport() {
        let app = launch(["--fixture-disconnected-camera", "--fixture-held-recipes"])
        let status = app.buttons["app.status"]
        guard status.value as? String == "Camera disconnected" else {
            XCTFail("The disconnected indicator must expose the no-camera state")
            return
        }
        app.cells["grid.source-0"].tap()
        let versions = app.buttons["workspace.versions"]
        XCTAssertTrue(versions.waitForExistence(timeout: 5))
        wait { app.scrollViews["viewer.image"].exists && !app.descendants(matching: .any)["viewer.loading"].exists }
        let frame = status.frame
        XCTAssertEqual(frame.width, versions.frame.width, accuracy: 1)
        XCTAssertEqual(frame.height, versions.frame.height, accuracy: 1)
        shot(app, "Crossed-out camera before connection")
        app.buttons["fixture.plugInCamera"].tap()
        wait { status.value as? String == "Preparing camera" }
        for _ in 0..<3 {
            app.buttons["fixture.cycleRecipeCamera"].tap()
            XCTAssertEqual(status.value as? String, "Preparing camera", "Busy/ready updates must not interrupt recipe-loading presentation")
            XCTAssertEqual(status.frame, frame)
        }
        shot(app, "Spinning camera while recipes download")
        app.buttons["fixture.finishRecipes"].tap()
        wait { status.value as? String == "Camera ready" }
        XCTAssertEqual(status.frame, frame)
        shot(app, "Ready camera after recipe download")
    }

    func testDisconnectedRecipeMenuSelectsNoneAndDisablesCachedRecipesAndRefresh() {
        let app = launch(["--fixture-disconnected-camera"])
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
        app.buttons["fixture.plugInCamera"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["recipe.control"], in: app)
        XCTAssertTrue(none.waitForExistence(timeout: 5))
        XCTAssertTrue(none.isSelected)
        for slot in 1...6 { XCTAssertTrue(app.buttons["recipe.slot.\(slot)"].isEnabled) }
        XCTAssertFalse(app.buttons["recipe.slot.7"].isEnabled)
        XCTAssertTrue(app.buttons["recipe.refresh"].isEnabled)
    }

    func testPreviewDisconnectClearsRecipeAndAutomaticallyReconnectsAtLargestText() {
        let app = launch(["--fixture-preview-failure", "--fixture-accessibility"])
        app.cells["grid.source-0"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout: 5))
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(1, in: app)
        wait { app.buttons["recipe.control"].label == "No recipe selected" }
        XCTAssertTrue(app.scrollViews["viewer.image"].exists)
        XCTAssertGreaterThan(app.scrollViews["viewer.image"].frame.height, 40)
        XCTAssertEqual(app.buttons["workspace.versions"].value as? String, "Original camera JPEG")
        XCTAssertFalse(app.buttons["workspace.export"].exists)
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["recipe.control"], in: app)
        XCTAssertTrue(app.buttons["recipe.none"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["recipe.none"].isSelected)
        XCTAssertTrue(app.buttons["recipe.none"].isEnabled)
        for slot in 1...6 { XCTAssertTrue(app.buttons["recipe.slot.\(slot)"].isEnabled) }
        XCTAssertFalse(app.buttons["recipe.slot.7"].isEnabled)
        XCTAssertTrue(app.buttons["recipe.refresh"].isEnabled)
        shot(app, "Automatic reconnect keeps recipe cleared at AX5")
        tap(app.buttons["recipe.none"], in: app)
        XCTAssertTrue(app.scrollViews["viewer.image"].isHittable)
        for id in ["viewer.zoomOut", "viewer.fit", "viewer.zoomIn"] { XCTAssertFalse(app.buttons[id].exists) }
        let grid = app.collectionViews["photoGrid"], first = app.cells["grid.source-0"].frame
        let side = first.width, headerHeight = first.minY - grid.frame.minY
        XCTAssertGreaterThan(grid.frame.height, side)
        XCTAssertGreaterThan(headerHeight, 0)
        XCTAssertEqual(grid.frame.height, headerHeight + side + 34, accuracy: 1)
        let frame = app.scrollViews["viewer.image"].frame
        app.buttons["drawer.toggle"].tap(); wait { app.buttons["drawer.toggle"].value as? String == "Expanded" }
        XCTAssertFalse(app.buttons["viewer.zoomIn"].exists)
        app.buttons["drawer.toggle"].tap(); wait { app.buttons["drawer.toggle"].value as? String == "Collapsed" }
        XCTAssertEqual(app.scrollViews["viewer.image"].frame, frame)
    }
}
