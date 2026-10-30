import XCTest

@MainActor
final class PhotoControlsTests: AppFlowTestCase {
    func testRepeatedPhotoSelectionKeepsLoadingOverlayUntilRecipeConversionFinishes() {
        let app = launch(["--fixture-held-conversion"])
        app.cells["grid.source-0"].tap()
        let loading = app.descendants(matching: .any)["viewer.loading"]
        wait { app.scrollViews["viewer.image"].exists && !loading.exists }
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(1, in: app)
        wait { app.buttons["fixture.finishPreview"].value as? String == "Loading preview" }

        for sourceID in ["source-2", "source-1", "source-0", "source-2", "source-2"] {
            app.cells["grid.\(sourceID)"].tap()
            XCTAssertTrue(app.scrollViews["viewer.image"].exists)
            XCTAssertTrue(loading.exists, "The selected recipe is still waiting for camera conversion")
            XCTAssertFalse(app.buttons["workspace.export"].isEnabled)
        }
        shot(app, "Repeated photo selection stays under the loading overlay")
        app.buttons["fixture.finishPreview"].tap()
        wait { !loading.exists && app.buttons["workspace.export"].isEnabled }
        XCTAssertTrue(app.scrollViews["viewer.image"].exists)
        XCTAssertTrue(app.buttons["recipe.control"].label.contains("C1"))
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

    func testFloatingStatusAndRightAlignedPhotoControlsGiveSpaceBackToPhoto() {
        let app = launch()
        app.cells["grid.source-0"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout: 5))
        assertFloatingPhotoControls(app)
        XCTAssertEqual(app.buttons["app.status"].frame.width, app.buttons["workspace.versions"].frame.width, accuracy: 1)
        XCTAssertEqual(app.buttons["app.status"].frame.height, app.buttons["workspace.versions"].frame.height, accuracy: 1)
        tap(app.buttons["app.status"], in: app)
        XCTAssertTrue(app.staticTexts["app.access"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        assertFloatingPhotoControls(app)
        shot(app, "Floating camera icon and right-aligned recipe and versions over photo")
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
        XCTAssertFalse(select.frame.intersects(app.buttons["drawer.toggle"].frame))
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

    func testAXPinchInspectionStaysSeparateFromEnabledRecipeVersionsAndExport() {
        let app = launch(["--fixture-accessibility", "--fixture-dark"])
        app.cells["grid.source-0"].tap(); wait { app.buttons["app.status"].label.contains("Camera ready") }
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
        let frame = viewer.frame, first = app.cells["grid.source-0"].frame
        let side = first.width, dayHeaderHeight = first.minY - grid.frame.minY
        XCTAssertGreaterThan(grid.frame.height, side)
        XCTAssertEqual(grid.frame.height, dayHeaderHeight + side + 34, accuracy: 1)
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
        XCTAssertEqual(grid.frame.height, dayHeaderHeight + side + 34, accuracy: 1)
        inspect("AX5 recollapsed pinch inspection remains operable without export")
        // Floating controls over letterboxing can report isHittable == false to XCTest.
        // Verify a real screen tap still exports the selected recipe after inspection.
        tap(app.buttons["workspace.export"], in: app)
        wait { app.buttons["app.status"].label.contains("1 saved") }
        XCTAssertFalse(app.buttons["workspace.versions"].exists)
    }

    func testAccessibleFloatingPhotoControlsRemainSeparateWithoutConnect() {
        let app = launch(["--fixture-accessibility", "--fixture-limited", "--fixture-dark"])
        app.cells["grid.source-0"].tap()
        assertFloatingPhotoControls(app)
        XCTAssertGreaterThanOrEqual(app.buttons["app.status"].frame.height, 44)
        XCTAssertFalse(app.buttons["app.connect"].exists)
        XCTAssertFalse(app.buttons["app.status"].frame.intersects(app.buttons["recipe.control"].frame))
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
