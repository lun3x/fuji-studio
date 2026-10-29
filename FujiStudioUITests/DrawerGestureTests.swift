import XCTest

@MainActor
final class DrawerGestureTests: WorkspaceTestCase {
    func testCollapsedRowsAndExpandedBrowseTapPreserveViewerFrame() {
        let app = launch(), grid = app.collectionViews["photoGrid"]
        let side = tile(app, 0).frame.width, viewer = app.scrollViews["viewer.image"]
        XCTAssertTrue(viewer.waitUntilExists(timeout: 10))
        XCTAssertGreaterThan(grid.frame.height, side)
        XCTAssertLessThan(grid.frame.height, side * 2)
        XCTAssertEqual(viewer.frame.width, grid.frame.width, accuracy: 0.5)
        XCTAssertEqual(tile(app, 0).frame.width, tile(app, 0).frame.height, accuracy: 0.5)
        let base = viewer.frame
        let nextRow = tile(app, 3)
        XCTAssertTrue(nextRow.exists)
        let peek = nextRow.frame.intersection(grid.frame)
        XCTAssertGreaterThan(peek.height, 0)
        XCTAssertLessThan(peek.height, side)
        shot(app, "Workspace light collapsed")
        app.buttons["drawer.toggle"].tap()
        XCTAssertEqual(app.buttons["drawer.toggle"].value as? String, "Expanded")
        waitForDetent(app, expanded: true)
        XCTAssertEqual(app.buttons["drawer.toggle"].value as? String, "Expanded")
        XCTAssertGreaterThan(grid.frame.height, side * 2 + 19)
        XCTAssertGreaterThanOrEqual(app.buttons["drawer.toggle"].frame.minY, app.buttons["recipe.control"].frame.maxY)
        tile(app, 1).tap()
        XCTAssertEqual(app.buttons["drawer.toggle"].value as? String, "Expanded")
        XCTAssertEqual(viewer.frame, base)
        assertRecipeControlUsable(app)
        assertExportControlUsable(app)
        shot(app, "Workspace light expanded browse")
    }

    func testSelectTapManualCollapseRevealsViewedAndRetainsChecks() {
        let app = launch(), grid = app.collectionViews["photoGrid"]
        app.buttons["drawer.toggle"].tap()
        XCTAssertEqual(app.buttons["drawer.toggle"].value as? String, "Expanded")
        waitForDetent(app, expanded: true)
        let frame = tile(app, 0).frame
        app.buttons["workspace.select"].tap()
        XCTAssertEqual(tile(app, 0).frame, frame)
        tile(app, 1).tap()
        XCTAssertEqual(app.buttons["drawer.toggle"].value as? String, "Expanded")
        grid.swipeUp()
        let visible = app.cells.allElementsBoundByIndex.filter { $0.isHittable && $0.frame.minY >= grid.frame.minY && $0.frame.maxY <= grid.frame.maxY }
        XCTAssertFalse(visible.isEmpty)
        let viewed = visible.last!
        let id = viewed.identifier
        viewed.tap()
        XCTAssertEqual(app.staticTexts["workspace.count"].label, "3 selected")
        app.buttons["drawer.toggle"].tap()
        XCTAssertEqual(app.buttons["drawer.toggle"].value as? String, "Collapsed")
        waitForDetent(app, expanded: false)
        let final = app.cells[id]
        XCTAssertGreaterThanOrEqual(final.frame.minY, grid.frame.minY - 0.5)
        XCTAssertLessThanOrEqual(final.frame.maxY, grid.frame.maxY + 0.5)
        XCTAssertEqual(final.value as? String, "Checked")
        XCTAssertEqual(app.staticTexts["workspace.count"].label, "3 selected")
        app.buttons["workspace.select"].tap()
        XCTAssertFalse(final.isSelected)
        XCTAssertEqual(app.buttons["workspace.select"].label, "Select")
        XCTAssertFalse(app.staticTexts["workspace.count"].exists)
        shot(app, "Workspace minimum reveal after collapse")
    }

    func testPullingPhotosDownAtTopCollapsesTrayWithoutChangingSelection() {
        let app = launch(["--fixture-drawer-trace"])
        let header = app.buttons["drawer.toggle"], grid = app.collectionViews["photoGrid"]
        for selecting in [false, true] {
            if selecting { app.buttons["workspace.select"].tap(); tile(app, 1).tap() }
            header.tap(); waitForDetent(app, expanded: true)
            let before = drawerTrace(app)
            let viewed = app.staticTexts["fixture.viewed"].label, checks = countLabel(app)
            let start = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.15))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: grid.frame.height * 0.75)),
                withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertEqual(header.value as? String, "Collapsed")
            waitForDetent(app, expanded: false)
            assertTrajectory(Array(drawerTrace(app).dropFirst(max(0, before.count - 1))), opening: false)
            XCTAssertEqual(app.staticTexts["fixture.viewed"].label, viewed)
            XCTAssertEqual(countLabel(app), checks)
            XCTAssertEqual(app.staticTexts["fixture.exportCount"].label, "Export requests: 0")
        }
        shot(app, "Photo pull collapses tray and keeps selection")
    }

    func testHeaderDragChangesDetentWhileScrollingFurtherIntoPhotosDoesNot() {
        let app = launch()
        let header = app.buttons["drawer.toggle"]
        let begin = header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.2))
        begin.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertEqual(header.value as? String, "Expanded")
        app.collectionViews["photoGrid"].swipeUp()
        XCTAssertEqual(header.value as? String, "Expanded")
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.85)))
        XCTAssertEqual(header.value as? String, "Collapsed")
    }
}
