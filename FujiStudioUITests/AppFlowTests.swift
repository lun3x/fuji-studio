import XCTest

@MainActor
final class AppFlowTests: AppFlowTestCase {
    func testXT5RecipesAreDisabledForMixedPhotoSelection() {
        assertRecipesDisabledForMixedPhotoSelection(flags: [])
    }

    func testXE3RecipesAreDisabledForMixedPhotoSelection() {
        assertRecipesDisabledForMixedPhotoSelection(flags: ["--fixture-xe3"])
    }

    private func assertRecipesDisabledForMixedPhotoSelection(flags: [String]) {
        let app = launch(flags + ["--fixture-filter-sources"])
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        // Assess all three originals, including the wrong model and unsupported geometry.
        tap(app.buttons["workspace.filter"], in: app); app.buttons["filter.compatible"].tap()
        wait {
            app.cells["grid.source-0"].exists && !app.staticTexts["filter.progress"].exists &&
                !app.cells["grid.source-1"].exists && !app.cells["grid.source-2"].exists
        }
        tap(app.buttons["workspace.filter"], in: app); app.buttons["filter.all"].tap()
        for incompatibleID in ["source-1", "source-2"] {
            app.cells["grid.\(incompatibleID)"].tap()
            app.buttons["workspace.select"].tap()
            app.cells["grid.source-0"].tap()
            wait { app.staticTexts["workspace.count"].label == "2 selected" }
            tap(app.buttons["recipe.control"], in: app)
            for slot in 1...7 { XCTAssertFalse(app.buttons["recipe.slot.\(slot)"].isEnabled) }
            XCTAssertTrue(app.buttons["recipe.none"].isEnabled)
            XCTAssertTrue(app.buttons["recipe.refresh"].isEnabled)
            shot(app, "Camera recipes disabled for \(incompatibleID) in mixed selection")
            let copy = app.buttons["recipe.copy.3"]
            XCTAssertTrue(copy.isEnabled)
            reveal(copy, in: app); copy.tap()
            let phone = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.phone.")).firstMatch
            XCTAssertTrue(phone.waitForExistence(timeout: 5))
            XCTAssertFalse(phone.isEnabled)
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.edit.")).firstMatch.isEnabled)
            shot(app, "Recipes disabled for \(incompatibleID) in mixed selection")
            tap(app.buttons["recipe.none"], in: app)
            app.cells["grid.\(incompatibleID)"].tap()
            wait { app.staticTexts["workspace.count"].label == "1 selected" }
            tap(app.buttons["recipe.control"], in: app)
            for slot in 1...6 { XCTAssertTrue(app.buttons["recipe.slot.\(slot)"].isEnabled) }
            app.segmentedControls["recipe.collection"].buttons["Phone"].tap()
            XCTAssertTrue(phone.isEnabled)
            tap(app.buttons["recipe.none"], in: app)
            app.buttons["workspace.select"].tap()
        }
    }

    func testCameraFilterFailureStatusStaysInsideBothLandscapeTrays() {
        let app = launch(["--fixture-filter-sources", "--fixture-filter-unavailable"])
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["workspace.filter"], in: app); app.buttons["filter.compatible"].tap()
        let status = app.staticTexts["filter.unavailable"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation: UIDeviceOrientation in [.landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            wait {
                let window = app.windows.firstMatch.frame, tray = app.collectionViews["photoGrid"].frame
                return window.width > window.height &&
                    (orientation == .landscapeLeft ? tray.minX > window.midX : tray.maxX < window.midX)
            }
            let window = app.windows.firstMatch.frame, tray = app.collectionViews["photoGrid"].frame
            XCTAssertTrue(window.contains(status.frame), "Status must fit the window: \(status.frame)")
            XCTAssertTrue(tray.contains(status.frame), "Status must remain inside the tray: \(status.frame)")
            shot(app, "Camera filter failure status \(orientation.rawValue)")
            let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screen.name = "Camera filter status full screen \(orientation.rawValue)"; screen.lifetime = .keepAlways; add(screen)
        }
    }

    func testCameraFilterMenuUsesConnectedXT5AndRestoresAllPhotos() {
        let app = launch(["--fixture-filter-sources"])
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        XCTAssertEqual(app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "grid.source-")).count, 3)
        let filter = app.buttons["workspace.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        tap(filter, in: app)
        let compatible = app.buttons["filter.compatible"]
        XCTAssertTrue(compatible.waitForExistence(timeout: 5))
        XCTAssertTrue(compatible.label.contains("Compatible with X-T5"))
        shot(app, "X-T5 filter menu")
        compatible.tap()
        wait { app.cells["grid.source-0"].exists && !app.cells["grid.source-1"].exists && !app.cells["grid.source-2"].exists }
        XCTAssertTrue(filter.value as? String == "Compatible with X-T5")
        shot(app, "X-T5 compatible photos")
        tap(filter, in: app); app.buttons["filter.all"].tap()
        wait { app.cells["grid.source-1"].exists && app.cells["grid.source-2"].exists }
    }

    func testXE3CameraFilterPrunesBatchAndKeepsViewer() {
        let app = launch(["--fixture-xe3", "--fixture-filter-sources", "--fixture-dark"])
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["workspace.filter"], in: app); app.buttons["filter.compatible"].tap()
        wait { app.cells["grid.source-0"].exists && !app.cells["grid.source-2"].exists }
        tap(app.buttons["workspace.filter"], in: app); app.buttons["filter.all"].tap()
        app.cells["grid.source-0"].tap(); app.buttons["workspace.select"].tap()
        app.cells["grid.source-2"].tap()
        wait { app.staticTexts["workspace.count"].label == "2 selected" }
        tap(app.buttons["workspace.filter"], in: app)
        XCTAssertTrue(app.buttons["filter.compatible"].label.contains("Compatible with X-E3"))
        app.buttons["filter.compatible"].tap()
        wait { app.staticTexts["workspace.count"].label == "1 selected" && !app.cells["grid.source-2"].exists }
        XCTAssertTrue(app.scrollViews["viewer.image"].exists)
        XCTAssertTrue(app.cells["grid.source-0"].exists)
        shot(app, "X-E3 filter in selection dark")
        app.buttons["workspace.select"].tap()
        XCTAssertFalse(app.staticTexts["workspace.count"].exists)
    }

    func testCameraFilterEmptyResultsLeaveMenuReachable() {
        let app = launch()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["workspace.filter"], in: app); app.buttons["filter.compatible"].tap()
        XCTAssertTrue(app.staticTexts["filter.empty"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["workspace.filter"].isHittable)
        shot(app, "Empty camera filter")
        tap(app.buttons["workspace.filter"], in: app); app.buttons["filter.all"].tap()
        XCTAssertTrue(app.cells["grid.source-0"].waitForExistence(timeout: 5))
    }

    func testCameraFilterSitsBesideSelectAndBelowItInLandscape() {
        let app = XCUIApplication(); app.launchArguments = ["--workspace-fixture", "--fixture-filter-sources"]; app.launch()
        XCTAssertTrue(app.buttons["workspace.filter"].waitForExistence(timeout: 10))
        let filter = app.buttons["workspace.filter"], select = app.buttons["workspace.select"]
        XCTAssertEqual(select.frame.minX - filter.frame.maxX, 12, accuracy: 1)
        XCTAssertEqual(filter.frame.midY, select.frame.midY, accuracy: 1)
        select.tap()
        let counter = app.staticTexts["workspace.count"]
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        XCTAssertEqual(counter.frame.minX, 12, accuracy: 1)
        XCTAssertEqual(select.frame.minX - filter.frame.maxX, 12, accuracy: 1)
        app.buttons["drawer.toggle"].tap()
        wait {
            app.buttons["workspace.filter"].frame.maxY < app.cells["grid.source-0"].frame.maxY &&
                app.collectionViews["photoGrid"].frame.minY < 200
        }
        tap(app.buttons["workspace.filter"], in: app)
        XCTAssertTrue(app.buttons["filter.compatible"].waitForExistence(timeout: 5))
        app.buttons["filter.compatible"].tap()
        wait { !app.cells["grid.source-1"].exists }
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation: UIDeviceOrientation in [.landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            wait {
                let window = app.windows.firstMatch.frame, tray = app.collectionViews["photoGrid"].frame
                return window.width > window.height && abs(tray.height - window.height) < 1 &&
                    (orientation == .landscapeLeft ? abs(tray.maxX - window.maxX) < 1 : abs(tray.minX - window.minX) < 1)
            }
            XCTAssertEqual(filter.frame.minY - select.frame.maxY, 12, accuracy: 1)
            XCTAssertGreaterThan(counter.frame.minY, app.windows.firstMatch.frame.midY)
            XCTAssertTrue(filter.isHittable); XCTAssertTrue(select.isHittable)
            let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screen.name = "Filter below Select with counter preserved \(orientation.rawValue)"; screen.lifetime = .keepAlways; add(screen)
            tap(filter, in: app)
            XCTAssertTrue(app.buttons["filter.all"].waitForExistence(timeout: 5))
            app.buttons["filter.compatible"].tap()
        }
    }

    func testXT5EditorSavesMissingRecipeOptionsAndReopensThem() {
        let app = launch(["--fixture-disconnected-camera"])
        tap(app.buttons["recipe.control"], in: app); app.buttons["recipe.copy.1"].tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.edit.")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        let film = app.buttons["recipe.editor.setting.film"]
        film.tap(); app.buttons["REALA ACE"].tap()
        let dynamicRange = app.buttons["recipe.editor.setting.dynamicRange"]
        dynamicRange.tap(); app.buttons["200%"].tap()
        let balance = app.buttons["recipe.editor.setting.whiteBalance"]
        reveal(balance, in: app); balance.tap(); app.buttons["Auto · White priority"].tap()
        app.buttons["recipe.editor.save"].tap()
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(film.label.contains("REALA ACE") || (film.value as? String ?? "").contains("REALA ACE"))
        XCTAssertTrue(dynamicRange.label.contains("200%") || (dynamicRange.value as? String ?? "").contains("200%"))
        reveal(balance, in: app)
        XCTAssertTrue(balance.label.contains("White priority") || (balance.value as? String ?? "").contains("White priority"))
        balance.tap(); app.buttons["Custom 3"].tap()
        reveal(dynamicRange, in: app); dynamicRange.tap(); app.buttons["Auto"].tap()
        app.buttons["recipe.editor.save"].tap()
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(dynamicRange.label.contains("Auto") || (dynamicRange.value as? String ?? "").contains("Auto"))
        reveal(balance, in: app)
        XCTAssertTrue(balance.label.contains("Custom 3") || (balance.value as? String ?? "").contains("Custom 3"))
        shot(app, "Complete X-T5 recipe options saved and reopened")
        app.buttons["recipe.editor.cancel"].tap()
    }
    func testInjectedFlowOpensRealWorkspaceWithoutSystemPermissions() {
        let app = launch()
        XCTAssertFalse(app.buttons["app.connect"].exists)
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
        app.cells["grid.source-0"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitUntilExists(timeout: 5))
        XCTAssertFalse(app.buttons["workspace.export"].exists)
        shot(app, "Automatically connected paired original")
    }

    func testInitiallyInactiveStartupWaitsForForegroundBeforeConnecting() {
        let app = launch(["--fixture-initial-inactive", "--fixture-scene-controls"])
        XCTAssertFalse(app.buttons["app.connect"].exists)
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.staticTexts["app.camera"].waitUntilExists(timeout: 5))
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
        XCTAssertTrue(versions.waitUntilExists(timeout: 5))
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
        XCTAssertTrue(none.waitUntilExists(timeout: 5))
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
        XCTAssertTrue(none.waitUntilExists(timeout: 5))
        XCTAssertTrue(none.isSelected)
        for slot in 1...6 { XCTAssertTrue(app.buttons["recipe.slot.\(slot)"].isEnabled) }
        XCTAssertFalse(app.buttons["recipe.slot.7"].isEnabled)
        XCTAssertTrue(app.buttons["recipe.refresh"].isEnabled)
    }

    func testPreviewDisconnectClearsRecipeAndAutomaticallyReconnectsAtLargestText() {
        let app = launch(["--fixture-preview-failure", "--fixture-accessibility"])
        app.cells["grid.source-0"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitUntilExists(timeout: 5))
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(1, in: app)
        wait { app.buttons["recipe.control"].label == "No recipe selected" }
        XCTAssertTrue(app.scrollViews["viewer.image"].exists)
        XCTAssertGreaterThan(app.scrollViews["viewer.image"].frame.height, 40)
        XCTAssertEqual(app.buttons["workspace.versions"].value as? String, "Original camera JPEG")
        XCTAssertFalse(app.buttons["workspace.export"].exists)
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["recipe.control"], in: app)
        XCTAssertTrue(app.buttons["recipe.none"].waitUntilExists(timeout: 5))
        XCTAssertTrue(app.buttons["recipe.none"].isSelected)
        XCTAssertTrue(app.buttons["recipe.none"].isEnabled)
        for slot in 1...6 { XCTAssertTrue(app.buttons["recipe.slot.\(slot)"].isEnabled) }
        XCTAssertFalse(app.buttons["recipe.slot.7"].isEnabled)
        XCTAssertTrue(app.buttons["recipe.refresh"].isEnabled)
        shot(app, "Automatic reconnect keeps recipe cleared at AX5")
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
}
