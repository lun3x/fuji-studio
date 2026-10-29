import XCTest

@MainActor
final class PhotoGridTests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--grid-fixture"]; app.launch()
        XCTAssertTrue(app.collectionViews["photoGrid"].waitForExistence(timeout: 10)); return app
    }
    private func tile(_ app: XCUIApplication, _ n: Int) -> XCUIElement { app.cells["grid.source-\(n)"] }
    func testVerticalScrollBothModesAndSelectKeepsTileAndAnchor() {
        let app = launch(), grid = app.collectionViews["photoGrid"]
        let first = tile(app, 0).frame
        app.buttons["Select"].tap()
        XCTAssertEqual(tile(app, 0).frame, first)
        grid.swipeUp()
        XCTAssertFalse(tile(app, 0).isHittable)
        let visible = app.cells.allElementsBoundByIndex.first(where: \.isHittable)!
        let id = visible.identifier, frame = visible.frame
        app.buttons["Cancel selection"].tap()
        XCTAssertEqual(app.cells[id].frame, frame)
        grid.swipeUp(); XCTAssertFalse(app.cells[id].isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Vertical square grid"; shot.lifetime = .keepAlways; add(shot)
    }
    func testAccessibleTapTogglesSelectionAndCancelClearsChecks() {
        let app = launch()
        app.buttons["Select"].tap(); tile(app, 0).tap()
        XCTAssertEqual(app.staticTexts["gridFixture.checked"].label, "Checked: 1")
        XCTAssertEqual(tile(app, 0).value as? String, "Checked")
        tile(app, 0).tap(); XCTAssertEqual(app.staticTexts["gridFixture.checked"].label, "Checked: 0")
        tile(app, 1).tap()
        app.buttons["Cancel selection"].tap()
        XCTAssertEqual(app.staticTexts["gridFixture.checked"].label, "Checked: 0")
        XCTAssertFalse(tile(app, 1).isSelected)
    }
    func testCheckedStartSweepRemovesAndEdgeScrollExtendsRange() {
        let app = launch(), grid = app.collectionViews["photoGrid"]
        app.buttons["Select"].tap()
        for index in 0...2 { tile(app, index).tap() }
        let start = tile(app, 0).coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let end = tile(app, 2).coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertEqual(app.staticTexts["gridFixture.checked"].label, "Checked: 0")
        let edgeStart = tile(app, 6).coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        edgeStart.press(forDuration: 0.05, thenDragTo: grid.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.97)), withVelocity: .slow, thenHoldForDuration: 2)
        let count = Int(app.staticTexts["gridFixture.checked"].label.replacingOccurrences(of: "Checked: ", with: "")) ?? 0
        XCTAssertGreaterThan(count, 24)
        XCTAssertEqual(app.staticTexts["gridFixture.viewed"].label, "Viewed: source-2")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Sweep edge autoscroll past initial cells"; shot.lifetime = .keepAlways; add(shot)
    }
    func testFinalTwoRowViewportRevealsViewedTileAndPreservesCheckedSet() {
        let app = launch(), grid = app.collectionViews["photoGrid"]
        app.buttons["Select"].tap(); tile(app, 8).tap()
        let side = tile(app, 8).frame.width
        app.buttons["Resize"].tap()
        XCTAssertEqual(grid.frame.height, side * 2 + 3 + 16, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(tile(app, 8).frame.minY, grid.frame.minY)
        XCTAssertLessThanOrEqual(tile(app, 8).frame.maxY, grid.frame.maxY + 0.5)
        XCTAssertEqual(app.staticTexts["gridFixture.checked"].label, "Checked: 1")
        XCTAssertEqual(app.staticTexts["gridFixture.viewed"].label, "Viewed: source-8")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Exact two row fixture viewport after shrink"; shot.lifetime = .keepAlways; add(shot)
    }
}
