import XCTest

@MainActor
final class WorkspaceOrientationTests: XCTestCase {
    private func launch(_ flags: [String] = [], orientation: UIDeviceOrientation = .portrait) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["--workspace-fixture"] + flags
        app.launch()
        XCTAssertTrue(app.buttons["drawer.toggle"].waitForExistence(timeout: 10))
        return app
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        let frame = element.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }
    func testDayHeadersAndCheckboxesWorkInBothLandscapeDirections() {
        defer { XCUIDevice.shared.orientation = .portrait }
        for (orientation, accessibility) in [(UIDeviceOrientation.landscapeRight, false), (.landscapeLeft, false),
                                            (.landscapeRight, true), (.landscapeLeft, true)] {
            let flags = ["--fixture-dated-photos"] + (accessibility ? ["--fixture-accessibility"] : [])
            let app = launch(flags, orientation: orientation)
            let day = app.buttons["grid.day.2026-10-23"]
            XCTAssertTrue(day.waitForExistence(timeout: 5))
            XCTAssertFalse(day.frame.intersects(app.buttons["workspace.select"].frame))
            let date = app.staticTexts["Fri, Oct 23, 2026"]
            XCTAssertTrue(date.exists)
            XCTAssertGreaterThan(date.frame.width, 40)
            XCTAssertLessThan(date.frame.maxY, day.frame.minY)
            XCTAssertLessThan(date.frame.minY, app.windows.firstMatch.frame.midY)
            XCTAssertGreaterThan(day.frame.minY, app.windows.firstMatch.frame.midY)
            let filter = app.buttons["workspace.filter"], filterBefore = filter.frame
            let selectBefore = app.buttons["workspace.select"].frame
            XCTAssertGreaterThanOrEqual(selectBefore.minX, app.windows.firstMatch.frame.minX)
            XCTAssertLessThanOrEqual(selectBefore.maxX, app.windows.firstMatch.frame.maxX)
            XCTAssertFalse(date.frame.intersects(filterBefore))
            XCTAssertFalse(date.frame.intersects(selectBefore))
            tap(day, in: app)
            XCTAssertEqual(day.value as? String, "Checked")
            XCTAssertEqual(app.staticTexts["workspace.count"].label, "6 selected")
            XCTAssertEqual(filter.frame, filterBefore)
            let count = app.staticTexts["workspace.count"].frame
            let clear = app.buttons["workspace.select"].frame
            XCTAssertLessThanOrEqual(clear.maxY, count.minY)
            XCTAssertLessThanOrEqual(count.maxY, filter.frame.minY)
            XCTAssertEqual(clear.minY, selectBefore.minY, accuracy: 0.5)
            XCTAssertEqual(count.maxY, selectBefore.maxY, accuracy: 0.5)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Upright day divider \(orientation.rawValue) AX \(accessibility)"; shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }

    private func assertTrayFillsScreenHeight(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        let grid = app.collectionViews["photoGrid"].frame
        let handle = app.buttons["drawer.toggle"].frame
        XCTAssertEqual(grid.minY, window.minY, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(grid.maxY, window.maxY, accuracy: 0.5,
            "Photos must extend through the home-indicator area without a bottom strip", file: file, line: line)
        XCTAssertEqual(handle.minY, window.minY, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(handle.maxY, window.maxY, accuracy: 0.5, file: file, line: line)
    }

    func testPhoneRecipeEditorOpensInBothLandscapeDirections() {
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.landscapeRight, .landscapeLeft] {
            let app = launch(orientation: orientation)
            tap(app.buttons["recipe.control"], in: app)
            let copy = app.buttons["recipe.copy.1"]
            XCTAssertTrue(copy.waitForExistence(timeout: 5))
            copy.tap()
            let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.edit.")).firstMatch
            XCTAssertTrue(edit.waitForExistence(timeout: 5))
            edit.tap()
            let editor = app.navigationBars["Edit phone recipe"]
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            XCTAssertTrue(app.textFields["recipe.editor.name"].exists)
            XCTAssertTrue(app.buttons["recipe.editor.save"].isHittable)
            XCTAssertTrue(app.buttons["recipe.editor.cancel"].isHittable)
            app.buttons["recipe.editor.cancel"].tap()
            XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
            XCTAssertTrue(app.buttons["recipe.control"].label.contains("C3"))
            app.terminate()
        }
    }

    func testTrayAndControlsStayAtPhysicalDeviceEdgesInBothLandscapeDirections() {
        let app = launch(["--fixture-dark"])
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }

        for (orientation, trayOnLeft) in [(UIDeviceOrientation.landscapeRight, true), (.landscapeLeft, false)] {
            XCUIDevice.shared.orientation = orientation
            let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 8), .completed)
            let grid = app.collectionViews["photoGrid"], window = app.windows.firstMatch.frame
            let atEdge = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                grid.frame.height > grid.frame.width &&
                    (trayOnLeft ? grid.frame.maxX < window.midX : grid.frame.minX > window.midX)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [atEdge], timeout: 5), .completed,
                "The photo tray must stay beside the charging-port edge")
            assertTrayFillsScreenHeight(app)
            let bottomPhoto = app.cells["grid.source-\(trayOnLeft ? 2 : 0)"].frame
            XCTAssertEqual(bottomPhoto.maxY, window.maxY, accuracy: 0.5)
            let select = app.buttons["workspace.select"].frame
            XCTAssertLessThan(select.maxY, window.midY, "Select belongs at the top in either landscape direction")
            XCTAssertGreaterThanOrEqual(select.minY, window.minY + 8)
            let photo = app.scrollViews["viewer.image"].frame
            XCTAssertEqual(photo.minY, window.minY, accuracy: 0.5)
            XCTAssertEqual(photo.maxY, window.maxY, accuracy: 0.5,
                "The main photo viewport must include the home-indicator area")
            let recipe = app.buttons["recipe.control"].frame
            let status = app.buttons["app.status"].frame
            let export = app.buttons["workspace.export"].frame
            if trayOnLeft {
                XCTAssertGreaterThan(recipe.minX, window.midX)
                XCTAssertLessThan(status.midY, recipe.midY)
                XCTAssertLessThan(recipe.midY, export.midY)
            } else {
                XCTAssertLessThan(recipe.maxX, window.midX)
                XCTAssertGreaterThan(status.midY, recipe.midY)
                XCTAssertGreaterThan(recipe.midY, export.midY)
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = trayOnLeft ? "Landscape tray left" : "Landscape tray right"
            shot.lifetime = .keepAlways; add(shot)
        }
    }

    func testLandscapeTrayOpensSidewaysAndPreservesSelectionThroughRotation() {
        let app = launch()
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        app.buttons["workspace.select"].tap()
        app.cells["grid.source-1"].tap()
        let viewed = app.staticTexts["fixture.viewed"].label
        let selected = app.staticTexts["workspace.count"].label
        let grid = app.collectionViews["photoGrid"], handle = app.buttons["drawer.toggle"]
        for (orientation, distance) in [(UIDeviceOrientation.landscapeRight, 450.0), (.landscapeLeft, -450.0)] {
            XCUIDevice.shared.orientation = orientation
            let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                grid.frame.height > grid.frame.width && (distance > 0
                    ? grid.frame.maxX < app.windows.firstMatch.frame.midX
                    : grid.frame.minX > app.windows.firstMatch.frame.midX)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
            let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: distance, dy: 0)))
            XCTAssertEqual(handle.value as? String, "Expanded")
            assertTrayFillsScreenHeight(app)
            XCTAssertLessThan(app.buttons["workspace.select"].frame.maxY, app.windows.firstMatch.frame.midY)
            XCTAssertEqual(app.staticTexts["workspace.count"].label, selected)
            XCTAssertEqual(app.staticTexts["fixture.viewed"].label, viewed)
            let expanded = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            expanded.name = "Landscape expanded selection \(orientation.rawValue)"
            expanded.lifetime = .keepAlways; add(expanded)
            let pull = grid.coordinate(withNormalizedOffset: CGVector(dx: distance > 0 ? 0.85 : 0.15, dy: 0.5))
            pull.press(forDuration: 0.05, thenDragTo: pull.withOffset(CGVector(dx: -distance, dy: 0)),
                withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertEqual(handle.value as? String, "Collapsed")
        }

        tap(app.buttons["recipe.control"], in: app)
        XCTAssertTrue(app.buttons["recipe.none"].waitForExistence(timeout: 5))
        app.buttons["recipe.none"].tap()
        tap(app.buttons["workspace.versions"], in: app)
        XCTAssertTrue(app.buttons["version.cameraJPEG"].waitForExistence(timeout: 5))
        app.buttons["version.cameraJPEG"].tap()
        XCTAssertEqual(app.buttons["workspace.versions"].value as? String, "Original camera JPEG")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(app.staticTexts["workspace.count"].label, selected)
        XCTAssertEqual(app.staticTexts["fixture.viewed"].label, viewed)
    }

    func testLaunchingInEitherLandscapeDirectionSupportsLargestTextAndMenus() {
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.landscapeRight, .landscapeLeft] {
            let app = launch(["--fixture-accessibility"], orientation: orientation)
            let grid = app.collectionViews["photoGrid"]
            let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                grid.frame.height > grid.frame.width
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
            XCTAssertLessThan(app.buttons["workspace.select"].frame.maxY, app.windows.firstMatch.frame.midY)
            tap(app.buttons["workspace.select"], in: app)
            XCTAssertEqual(app.buttons["workspace.select"].label, "Cancel selection")
            tap(app.buttons["recipe.control"], in: app)
            XCTAssertTrue(app.buttons["recipe.none"].waitForExistence(timeout: 5))
            app.buttons["recipe.none"].tap()
            tap(app.buttons["workspace.versions"], in: app)
            let jpeg = app.buttons["version.cameraJPEG"]
            XCTAssertTrue(jpeg.waitForExistence(timeout: 5))
            XCTAssertTrue(jpeg.isHittable)
            jpeg.tap()
            XCTAssertEqual(app.buttons["workspace.versions"].value as? String, "Original camera JPEG")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Landscape launch AX5 \(orientation.rawValue)"; shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }
}
