import XCTest

@MainActor
final class WorkspaceOrientationTests: XCTestCase {
    private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--workspace-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["drawer.toggle"].waitForExistence(timeout: 10))
        return app
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        let frame = element.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
    }

    func testTrayAndControlsStayAtPhysicalDeviceEdgesInBothLandscapeDirections() {
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }

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
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = trayOnLeft ? "Landscape tray left" : "Landscape tray right"
            shot.lifetime = .keepAlways; add(shot)
        }
    }

    func testLandscapeTrayOpensSidewaysAndPreservesSelectionThroughRotation() {
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        app.buttons["workspace.select"].tap()
        app.cells["grid.source-1"].tap()
        let viewed = app.staticTexts["fixture.viewed"].label
        let selected = app.staticTexts["workspace.count"].label
        XCUIDevice.shared.orientation = .landscapeRight
        let grid = app.collectionViews["photoGrid"], handle = app.buttons["drawer.toggle"]
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            grid.frame.height > grid.frame.width && grid.frame.maxX < app.windows.firstMatch.frame.midX
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 450, dy: 0)))
        XCTAssertEqual(handle.value as? String, "Expanded")
        XCTAssertEqual(app.staticTexts["workspace.count"].label, selected)
        XCTAssertEqual(app.staticTexts["fixture.viewed"].label, viewed)
        let expanded = XCTAttachment(screenshot: app.screenshot())
        expanded.name = "Landscape expanded selection"; expanded.lifetime = .keepAlways; add(expanded)
        tap(handle, in: app)
        XCTAssertEqual(handle.value as? String, "Collapsed")

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
}
