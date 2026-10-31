import XCTest

@MainActor
final class TrayControlLayoutTests: WorkspaceTestCase {
    func testPortraitControlsStayOverPhotosAndFilterDoesNotMoveWhenSelecting() {
        let app = launch(["--fixture-dated-photos"])
        let filter = app.buttons["workspace.filter"], select = app.buttons["workspace.select"]
        let grid = app.collectionViews["photoGrid"], day = app.buttons["grid.day.2026-10-23"]
        let date = app.staticTexts["Fri, Oct 23, 2026"]
        let filterBefore = filter.frame, selectBefore = select.frame
        XCTAssertFalse(app.buttons["Cancel selection"].exists)
        XCTAssertGreaterThanOrEqual(selectBefore.minY, grid.frame.minY)
        XCTAssertFalse(selectBefore.intersects(app.buttons["drawer.toggle"].frame))
        XCTAssertLessThanOrEqual(day.frame.maxX, date.frame.minX)
        select.tap()
        XCTAssertFalse(app.buttons["Select"].exists)
        let count = app.staticTexts["workspace.count"]
        XCTAssertEqual(filter.frame, filterBefore)
        XCTAssertLessThanOrEqual(filter.frame.maxX, count.frame.minX)
        XCTAssertLessThanOrEqual(count.frame.maxX, select.frame.minX)
        XCTAssertEqual(count.frame.minX, selectBefore.minX, accuracy: 0.5)
        XCTAssertEqual(select.frame.maxX, selectBefore.maxX, accuracy: 0.5)
        XCTAssertFalse(date.frame.intersects(filter.frame))
        XCTAssertFalse(date.frame.intersects(count.frame))
        XCTAssertFalse(day.frame.intersects(select.frame))
        shot(app, "Portrait count between Filter and clear selection")
        select.tap()
        XCTAssertFalse(app.buttons["Cancel selection"].exists)
        XCTAssertEqual(select.frame, selectBefore)
        XCTAssertEqual(filter.frame, filterBefore)
        shot(app, "Portrait fixed filter and leading day check")
    }

    func testFilterStaysFixedWhenSelectedCountGainsADigit() {
        let app = launch(["--fixture-dated-photos"])
        app.buttons["drawer.toggle"].tap()
        waitForDetent(app, expanded: true)
        let filter = app.buttons["workspace.filter"], before = filter.frame
        app.buttons["grid.day.2026-10-23"].tap()
        XCTAssertEqual(app.staticTexts["workspace.count"].label, "6 selected")
        XCTAssertEqual(filter.frame, before)
        app.buttons["grid.day.2026-10-22"].tap()
        XCTAssertEqual(app.staticTexts["workspace.count"].label, "12 selected")
        XCTAssertEqual(filter.frame, before)
        app.buttons["workspace.select"].tap()
        XCTAssertEqual(filter.frame, before)
    }
    func testLargestTextKeepsDateAndDayCheckboxClearOfFloatingControls() {
        let app = launch(["--fixture-dated-photos", "--fixture-accessibility"])
        let day = app.buttons["grid.day.2026-10-23"]
        let date = app.staticTexts["Fri, Oct 23, 2026"]
        let filter = app.buttons["workspace.filter"], before = filter.frame
        XCTAssertTrue(day.waitForExistence(timeout: 5))
        XCTAssertFalse(date.frame.intersects(filter.frame))
        XCTAssertFalse(date.frame.intersects(app.buttons["workspace.select"].frame))
        XCTAssertLessThanOrEqual(day.frame.maxX, date.frame.minX)
        day.tap()
        XCTAssertEqual(app.staticTexts["workspace.count"].label, "6 selected")
        XCTAssertEqual(filter.frame, before)
        XCTAssertFalse(date.frame.intersects(app.staticTexts["workspace.count"].frame))
        shot(app, "Large text day header below floating controls")
    }
}
