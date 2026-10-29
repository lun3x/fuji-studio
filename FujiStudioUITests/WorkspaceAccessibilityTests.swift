import XCTest

@MainActor
final class WorkspaceAccessibilityTests: WorkspaceTestCase {
    func testDarkExpandedAndAccessibleHeaderAlternatives() {
        let app = launch(["--fixture-dark"])
        app.buttons["drawer.toggle"].tap()
        XCTAssertEqual(app.buttons["drawer.toggle"].value as? String, "Expanded")
        waitForDetent(app, expanded: true)
        app.buttons["workspace.select"].tap()
        // Verify real touch delivery where XCTest can report no hit point
        // for the glass header over the photo view.
        func tapHeader() {
            let header = app.buttons["drawer.toggle"].frame
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: header.midX, dy: header.midY)).tap()
        }
        tapHeader()
        XCTAssertEqual(app.buttons["drawer.toggle"].value as? String, "Collapsed")
        waitForDetent(app, expanded: false)
        tapHeader()
        XCTAssertEqual(app.buttons["drawer.toggle"].value as? String, "Expanded")
        waitForDetent(app, expanded: true)
        assertRecipeControlUsable(app)
        shot(app, "Workspace dark expanded Select")
        tapHeader()
        XCTAssertEqual(app.buttons["drawer.toggle"].value as? String, "Collapsed")
        waitForDetent(app, expanded: false)
        shot(app, "Workspace dark collapsed Select")
    }

    func testLargestTextDoesNotOverlap() {
        let app = launch(["--fixture-accessibility", "--fixture-stale"])
        let grid = app.collectionViews["photoGrid"]
        let side = tile(app, 0).frame.width
        XCTAssertGreaterThan(grid.frame.height, side)
        XCTAssertLessThan(grid.frame.height, side * 2)
        XCTAssertTrue(app.buttons["workspace.select"].isHittable)
        assertExportControlUsable(app)
        app.buttons["drawer.toggle"].tap()
        XCTAssertEqual(app.buttons["drawer.toggle"].value as? String, "Expanded")
        waitForDetent(app, expanded: true)
        XCTAssertGreaterThanOrEqual(app.buttons["drawer.toggle"].frame.minY, app.buttons["recipe.control"].frame.maxY)
        assertRecipeControlUsable(app)
        shot(app, "Workspace AX5 expanded")
        openRecipeMenu(app)
        XCTAssertTrue(app.staticTexts["recipe.stale"].waitUntilExists(timeout: 5))
        let options = app.scrollViews["recipe.options"]
        for _ in 0..<16 {
            let refresh = app.buttons["recipe.refresh"].frame
            if refresh.minY >= options.frame.minY && refresh.maxY <= options.frame.maxY { break }
            options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).press(forDuration: 0.05,
                thenDragTo: options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        }
        let refresh = app.buttons["recipe.refresh"].frame
        XCTAssertGreaterThanOrEqual(refresh.minY, options.frame.minY - 0.5)
        XCTAssertLessThanOrEqual(refresh.maxY, options.frame.maxY + 0.5)
        shot(app, "Workspace accessible recipe list, Refresh visible")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: refresh.midX, dy: refresh.midY)).tap()
        XCTAssertEqual(app.staticTexts["fixture.refreshCount"].label, "Refresh requests: 1")
        // The entire grabber label is a touch target, including its top-leading padding.
        // Without a label contentShape this touch misses and leaves the image covered.
        let toggle = app.buttons["drawer.toggle"]
        toggle.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 65.0 / 3, dy: 9)).tap()
        XCTAssertEqual(toggle.value as? String, "Collapsed")
        waitForDetent(app, expanded: false)

        for id in ["viewer.zoomOut", "viewer.fit", "viewer.zoomIn"] { XCTAssertFalse(app.buttons[id].exists) }
        let viewer = app.scrollViews["viewer.image"]
        XCTAssertFalse(app.buttons["workspace.versions"].exists)
        XCTAssertGreaterThanOrEqual(app.buttons["workspace.export"].frame.minY, viewer.frame.minY - 0.5)
        XCTAssertLessThanOrEqual(app.buttons["workspace.export"].frame.maxY, viewer.frame.maxY)
        let beforeZoom = [app.staticTexts["fixture.viewed"].label, countLabel(app), app.staticTexts["fixture.exportCount"].label, app.buttons["recipe.control"].label]
        viewer.pinch(withScale: 2.5, velocity: 1)
        let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            Double((app.scrollViews["viewer.image"].value as! String).split(separator: ",")[0])! > 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 5), .completed)
        XCTAssertGreaterThan(Double((app.scrollViews["viewer.image"].value as! String).split(separator: ",")[0])!, 1)
        shot(app, "Workspace AX5 actual zoom after manual collapse")
        viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).doubleTap()
        let fitted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(Double((app.scrollViews["viewer.image"].value as! String).split(separator: ",")[0])! - 1) < 0.01
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [fitted], timeout: 5), .completed)
        XCTAssertEqual(Double((app.scrollViews["viewer.image"].value as! String).split(separator: ",")[0])!, 1, accuracy: 0.01)
        XCTAssertEqual([app.staticTexts["fixture.viewed"].label, countLabel(app), app.staticTexts["fixture.exportCount"].label, app.buttons["recipe.control"].label], beforeZoom)
        XCTAssertFalse(app.buttons["workspace.export"].frame.intersects(app.buttons["recipe.control"].frame))
        openRecipeMenu(app)
        app.buttons["recipe.none"].tap()
        XCTAssertFalse(app.buttons["workspace.export"].exists)
        XCTAssertFalse(app.buttons["workspace.versions"].frame.intersects(app.buttons["recipe.control"].frame))
        app.buttons["workspace.versions"].tap()
        app.buttons["version.raw"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["viewer.unavailable"].waitUntilExists(timeout: 5))
        XCTAssertEqual(app.buttons["recipe.control"].label, "No recipe selected")
        app.buttons["workspace.versions"].tap()
        app.buttons["version.cameraJPEG"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitUntilExists(timeout: 5))
        XCTAssertEqual(app.buttons["workspace.versions"].value as? String, "Original camera JPEG")
        shot(app, "Workspace AX5 collapsed, zoom and versions usable")
    }

    func testActualViewportResizeKeepsGeometryAndControlsUsable() {
        let app = launch(["--fixture-compact"])
        let grid = app.collectionViews["photoGrid"]
        let original = grid.frame
        app.buttons["fixture.resize"].tap()
        XCTAssertNotEqual(grid.frame, original)
        let side = tile(app, 0).frame.width
        XCTAssertGreaterThanOrEqual(grid.frame.height, side - 0.5)
        XCTAssertLessThan(grid.frame.height, side * 2)
        app.buttons["drawer.toggle"].tap()
        XCTAssertEqual(app.buttons["drawer.toggle"].value as? String, "Expanded")
        waitForDetent(app, expanded: true)
        assertRecipeControlUsable(app)
        assertExportControlUsable(app)
        XCTAssertFalse(app.buttons["workspace.versions"].exists)
        shot(app, "Workspace actual compact viewport resize, not native rotation")
    }
}
