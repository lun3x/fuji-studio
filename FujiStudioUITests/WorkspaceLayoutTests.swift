import XCTest

@MainActor
final class WorkspaceLayoutTests: XCTestCase {
    private func launch(_ flags: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--workspace-fixture"] + flags
        app.launch()
        XCTAssertTrue(app.buttons["drawer.toggle"].waitForExistence(timeout: 10))
        return app
    }
    private func tile(_ app: XCUIApplication, _ n: Int) -> XCUIElement { app.cells["grid.source-\(n)"] }
    private func countLabel(_ app: XCUIApplication) -> String {
        let count = app.staticTexts["workspace.count"]
        return count.exists ? count.label : ""
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let metrics = XCTAttachment(string: "\(app.otherElements["fixture.nativeMetrics"].label)\nViewer \(app.scrollViews["viewer.image"].frame), value \(String(describing: app.scrollViews["viewer.image"].value)); Grid \(app.collectionViews["photoGrid"].frame); Export \(app.buttons["workspace.export"].frame); recipe \(app.buttons["recipe.control"].frame); drawer header \(app.buttons["drawer.toggle"].frame)")
        metrics.name = name + " native bounds"; metrics.lifetime = .keepAlways; add(metrics)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
    private func assertRecipeControlUsable(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let control = app.buttons["recipe.control"], rect = control.frame
        let before = [app.staticTexts["fixture.viewed"].label, countLabel(app), app.staticTexts["fixture.exportCount"].label, control.label]
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.midX, dy: rect.midY)).tap()
        XCTAssertTrue(app.buttons["recipe.slot.3"].waitForExistence(timeout: 5), file: file, line: line)
        // Tap above the popover in the measured Export region; native outside dismissal swallows it.
        let outside = app.buttons["workspace.export"].frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: outside.midX, dy: outside.midY)).tap()
        XCTAssertTrue(app.buttons["recipe.none"].waitForNonExistence(timeout: 3), file: file, line: line)
        XCTAssertEqual([app.staticTexts["fixture.viewed"].label, countLabel(app), app.staticTexts["fixture.exportCount"].label, control.label], before, file: file, line: line)
    }
    private func openRecipeMenu(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let rect = app.buttons["recipe.control"].frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.midX, dy: rect.midY)).tap()
        XCTAssertTrue(app.buttons["recipe.none"].waitForExistence(timeout: 5), file: file, line: line)
    }
    private func waitForDetent(_ app: XCUIApplication, expanded: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate { _, _ in
            let grid = app.collectionViews["photoGrid"]
            if expanded {
                let controls = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["recipe.control", "workspace.export", "workspace.versions"]))
                let bottom = controls.allElementsBoundByIndex.map { $0.frame.maxY }.max()!
                return abs(app.buttons["drawer.toggle"].frame.minY - bottom - 8) <= 1
            }
            let side = app.cells.allElementsBoundByIndex.first!.frame.width
            return grid.frame.height > side && grid.frame.height < side * 2
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5), .completed, file: file, line: line)
    }
    func testRecipeRowsRespondToBlankPadding() {
        let app = launch()
        openRecipeMenu(app)
        // Trailing padding is measured from the popover, outside the row text and checkmark.
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.scrollViews["recipe.options"].frame.maxX - 6, dy: app.buttons["recipe.slot.2"].frame.midY)).tap()
        XCTAssertTrue(app.buttons["recipe.none"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["recipe.control"].label.contains("C2"))
        openRecipeMenu(app)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.scrollViews["recipe.options"].frame.maxX - 6, dy: app.buttons["recipe.none"].frame.midY)).tap()
        XCTAssertTrue(app.buttons["recipe.none"].waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.buttons["recipe.control"].label, "No recipe selected")
        XCTAssertFalse(app.buttons["workspace.export"].isEnabled)
    }
    func testNativeHardwareEscapeDismissal() throws {
        guard ProcessInfo.processInfo.environment["FUJI_STUDIO_NATIVE_KEYBOARD"] == "1" else {
            throw XCTSkip("NOT VERIFIED: Duo physical-key synthesis reached neither native Escape nor independent k UIKeyCommand/pressesBegan, despite attached first responder/canPerformAction/target success. See task11-key-delivery-diagnostic.xcresult. Enable FUJI_STUDIO_NATIVE_KEYBOARD=1 on a validated keyboard destination.")
        }
        let app = launch(), before = app.buttons["recipe.control"].label
        openRecipeMenu(app)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["recipe.none"].waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.buttons["recipe.control"].label, before)
        openRecipeMenu(app)
        app.buttons["recipe.none"].tap()
        XCTAssertEqual(app.buttons["recipe.control"].label, "No recipe selected")
    }
    func testCollapsedRowsAndExpandedBrowseTapPreserveViewerFrame() {
        let app = launch(), grid = app.collectionViews["photoGrid"]
        let side = tile(app, 0).frame.width, viewer = app.scrollViews["viewer.image"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.buttons["workspace.export"].isHittable)
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
    func testRecipePopoverSelectionDismissClearAndRefresh() {
        let app = launch()
        XCTAssertTrue(app.buttons["recipe.control"].label.contains("C3"))
        let recipeFrame = app.buttons["recipe.control"].frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: recipeFrame.midX, dy: recipeFrame.midY)).tap()
        XCTAssertTrue(app.buttons["recipe.slot.3"].waitForExistence(timeout: 5))

        XCTAssertTrue(app.buttons["recipe.slot.3"].isSelected)
        let names = ["Soft daylight", "Warm shadows", "Mountain greens", "Quiet colour", "Evening light", "Monochrome", "Unsupported import"]
        for slot in 1...7 {
            XCTAssertTrue(app.buttons["recipe.slot.\(slot)"].label.contains("C\(slot) \(names[slot - 1])"))
        }
        XCTAssertTrue(app.buttons["recipe.slot.7"].label.contains("conversion unsupported"))

        // Native popover outside dismissal keeps the current recipe.
        shot(app, "Recipe C3 native popover")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.03)).tap()
        XCTAssertTrue(app.buttons["recipe.none"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["recipe.control"].label.contains("C3"))
        openRecipeMenu(app)
        app.buttons["recipe.none"].tap()

        XCTAssertEqual(app.buttons["recipe.control"].label, "No recipe selected")
        XCTAssertFalse(app.buttons["workspace.export"].isEnabled)
        openRecipeMenu(app)
        app.buttons["recipe.slot.3"].tap()
        XCTAssertTrue(app.buttons["workspace.export"].isEnabled)
        app.buttons["workspace.export"].tap()
        XCTAssertEqual(app.staticTexts["fixture.exportCount"].label, "Export requests: 1")
        app.buttons["workspace.versions"].tap()
        XCTAssertTrue(app.buttons["version.cameraJPEG"].isSelected)
        app.buttons["version.cameraJPEG"].tap()
        openRecipeMenu(app)

        let options = app.scrollViews["recipe.options"]
        options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).press(forDuration: 0.05, thenDragTo: options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        XCTAssertTrue(app.buttons["recipe.refresh"].isHittable)
        XCTAssertLessThanOrEqual(app.buttons["recipe.refresh"].frame.maxY, options.frame.maxY + 0.5)
        shot(app, "Recipe Refresh fully visible")
        app.buttons["recipe.refresh"].tap()

        XCTAssertEqual(app.staticTexts["fixture.refreshCount"].label, "Refresh requests: 1")
        XCTAssertTrue(app.buttons["recipe.control"].label.contains("C3"))
        openRecipeMenu(app)
        app.buttons["recipe.slot.7"].tap()
        XCTAssertTrue(app.buttons["recipe.control"].label.contains("C7"))
        XCTAssertFalse(app.buttons["workspace.export"].isEnabled)

    }
    func testDarkExpandedAndAccessibleHeaderAlternatives() {
        let app = launch(["--fixture-dark"])
        app.buttons["drawer.toggle"].tap()
        XCTAssertEqual(app.buttons["drawer.toggle"].value as? String, "Expanded")
        waitForDetent(app, expanded: true)
        app.buttons["workspace.select"].tap()
        XCTAssertTrue(app.buttons["drawer.toggle"].isHittable)
        assertRecipeControlUsable(app)
        shot(app, "Workspace dark expanded Select")
        app.buttons["drawer.toggle"].tap()
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
        XCTAssertTrue(app.buttons["workspace.export"].isHittable)
        app.buttons["drawer.toggle"].tap()
        XCTAssertEqual(app.buttons["drawer.toggle"].value as? String, "Expanded")
        waitForDetent(app, expanded: true)
        XCTAssertGreaterThanOrEqual(app.buttons["drawer.toggle"].frame.minY, app.buttons["recipe.control"].frame.maxY)
        assertRecipeControlUsable(app)
        shot(app, "Workspace AX5 expanded")
        openRecipeMenu(app)
        XCTAssertFalse(app.staticTexts["recipe.stale"].exists)
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
        XCTAssertGreaterThanOrEqual(app.buttons["workspace.versions"].frame.minY, viewer.frame.minY)
        XCTAssertLessThanOrEqual(app.buttons["workspace.versions"].frame.maxY, viewer.frame.maxY)
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
        XCTAssertFalse(app.buttons["workspace.versions"].frame.intersects(app.buttons["recipe.control"].frame))
        XCTAssertFalse(app.buttons["workspace.export"].frame.intersects(app.buttons["recipe.control"].frame))
        app.buttons["workspace.versions"].tap()
        app.buttons["version.raw"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["viewer.unavailable"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["recipe.control"].label.contains("C3"))
        app.buttons["workspace.versions"].tap()
        app.buttons["version.cameraJPEG"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["workspace.versions"].value as? String, "Original camera JPEG")
        shot(app, "Workspace AX5 collapsed, zoom and versions usable")
    }
    func testHeaderDragChangesDetentWhileGridScrollDoesNot() {
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
    private func drawerTrace(_ app: XCUIApplication) -> [Double] {
        (app.otherElements["fixture.nativeMetrics"].value as? String ?? "").split(separator: ",").compactMap { Double($0) }
    }
    private func assertTrajectory(_ values: [Double], opening: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let attachment = XCTAttachment(string: values.description); attachment.name = "Native grid top during drawer gesture"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertGreaterThan(values.count, 6, "Must observe actual intermediate native frames", file: file, line: line)
        for (previous, next) in zip(values, values.dropFirst()) {
            if opening { XCTAssertLessThanOrEqual(next, previous + 1.5, "Opening must not jump back down on release", file: file, line: line) }
            else { XCTAssertGreaterThanOrEqual(next, previous - 1.5, "Closing must not jump back up on release", file: file, line: line) }
        }
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
        XCTAssertTrue(app.buttons["workspace.export"].isHittable)
        XCTAssertTrue(app.buttons["workspace.versions"].exists)
        shot(app, "Workspace actual compact viewport resize, not native rotation")
    }
}
