import XCTest

@MainActor
final class DrawerTrajectoryTests: WorkspaceTestCase {
    func testShortPhotoPullSpringsBackAndScrollHandsOffOnlyAfterReachingTop() {
        let app = launch(["--fixture-drawer-trace"])
        let header = app.buttons["drawer.toggle"], grid = app.collectionViews["photoGrid"]
        header.tap(); waitForDetent(app, expanded: true)
        var before = drawerTrace(app)
        var start = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.2))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 70)),
            withVelocity: XCUIGestureVelocity(rawValue: 120), thenHoldForDuration: 0.3)
        waitForDetent(app, expanded: true)
        let partial = Array(drawerTrace(app).dropFirst(max(0, before.count - 1)))
        XCTAssertGreaterThan(partial.count, 6)
        XCTAssertGreaterThan((partial.max() ?? 0) - (partial.first ?? 0), 40, "The drawer must follow the finger before release")
        XCTAssertEqual(partial.first ?? -1, partial.last ?? -2, accuracy: 0.5)
        for (previous, next) in zip(partial, partial.dropFirst()) {
            XCTAssertLessThanOrEqual(abs(next - previous), 30, "A short pull must spring back without a height reset")
        }
        // Leave 140 points of photo content above the viewport, then scroll back 60.
        start = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.65))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -140)),
            withVelocity: XCUIGestureVelocity(rawValue: 200), thenHoldForDuration: 0.3)
        XCTAssertFalse(tile(app, 0).isHittable)
        before = drawerTrace(app)
        start = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.2))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 60)),
            withVelocity: XCUIGestureVelocity(rawValue: 120), thenHoldForDuration: 0.3)
        XCTAssertEqual(header.value as? String, "Expanded")
        XCTAssertEqual(drawerTrace(app).last ?? -1, before.last ?? -2, accuracy: 0.5)
        // One longer pull consumes the remaining scroll distance and then moves the tray.
        before = drawerTrace(app)
        start = grid.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.15))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: grid.frame.height * 0.75)),
            withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertEqual(header.value as? String, "Collapsed")
        waitForDetent(app, expanded: false)
        assertTrajectory(Array(drawerTrace(app).dropFirst(max(0, before.count - 1))), opening: false)
    }

    func testFullExpansionReleaseDoesNotReverseOrJump() {
        let app = launch(["--fixture-drawer-trace"]), handle = app.buttons["drawer.toggle"]
        let before = drawerTrace(app)
        handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 0.05,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)),
            withVelocity: .slow, thenHoldForDuration: 0.3)
        waitForDetent(app, expanded: true)
        assertTrajectory(Array(drawerTrace(app).dropFirst(max(0, before.count - 1))), opening: true)
        XCTAssertEqual(handle.value as? String, "Expanded")
        XCTAssertFalse(app.staticTexts["Expand photos"].exists)
        XCTAssertFalse(app.staticTexts["Collapse photos"].exists)
    }

    func testSlowPartialDragSettlesBackWithoutHeightReset() {
        let app = launch(["--fixture-drawer-trace"]), handle = app.buttons["drawer.toggle"]
        let before = drawerTrace(app), start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -70)),
            withVelocity: XCUIGestureVelocity(rawValue: 40), thenHoldForDuration: 0.3)
        XCTAssertEqual(handle.value as? String, "Collapsed")
        waitForDetent(app, expanded: false)
        let values = Array(drawerTrace(app).dropFirst(max(0, before.count - 1)))
        let attachment = XCTAttachment(string: values.description); attachment.name = "Same-detent release frames"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertGreaterThan(values.count, 6)
        XCTAssertEqual(values.first ?? -1, values.last ?? -2, accuracy: 0.5)
        for (previous, next) in zip(values, values.dropFirst()) {
            XCTAssertLessThanOrEqual(abs(next - previous), 30, "A slow 70-point drag must animate back rather than reset on release")
        }
    }

    func testShortFlicksUseMomentumInBothDirections() {
        let app = launch(["--fixture-drawer-trace"]), handle = app.buttons["drawer.toggle"]
        var before = drawerTrace(app)
        var start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -90)),
            withVelocity: XCUIGestureVelocity(rawValue: 2000), thenHoldForDuration: 0)
        XCTAssertEqual(handle.value as? String, "Expanded")
        waitForDetent(app, expanded: true)
        assertTrajectory(Array(drawerTrace(app).dropFirst(max(0, before.count - 1))), opening: true)
        before = drawerTrace(app); start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 90)),
            withVelocity: XCUIGestureVelocity(rawValue: 2000), thenHoldForDuration: 0)
        XCTAssertEqual(handle.value as? String, "Collapsed")
        waitForDetent(app, expanded: false)
        assertTrajectory(Array(drawerTrace(app).dropFirst(max(0, before.count - 1))), opening: false)
    }
}
