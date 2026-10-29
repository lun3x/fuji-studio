import XCTest

/// Shared fixture operations; concrete subclasses own all test methods.
@MainActor
class WorkspaceTestCase: XCTestCase {
    func launch(_ flags: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--workspace-fixture"] + flags
        app.launch()
        XCTAssertTrue(app.buttons["drawer.toggle"].waitForExistence(timeout: 10))
        return app
    }

    func tile(_ app: XCUIApplication, _ n: Int) -> XCUIElement { app.cells["grid.source-\(n)"] }

    func countLabel(_ app: XCUIApplication) -> String {
        let count = app.staticTexts["workspace.count"]
        return count.exists ? count.label : ""
    }

    func shot(_ app: XCUIApplication, _ name: String) {
        let export = app.buttons["workspace.export"]
        let metrics = XCTAttachment(string: "\(app.otherElements["fixture.nativeMetrics"].label)\nViewer \(app.scrollViews["viewer.image"].frame), value \(String(describing: app.scrollViews["viewer.image"].value)); Grid \(app.collectionViews["photoGrid"].frame); Export \(export.exists ? String(describing: export.frame) : "hidden"); recipe \(app.buttons["recipe.control"].frame); drawer header \(app.buttons["drawer.toggle"].frame)")
        metrics.name = name + " native bounds"; metrics.lifetime = .keepAlways; add(metrics)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }

    func assertRecipeControlUsable(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let control = app.buttons["recipe.control"], rect = control.frame
        let before = [app.staticTexts["fixture.viewed"].label, countLabel(app), app.staticTexts["fixture.exportCount"].label, control.label]
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.midX, dy: rect.midY)).tap()
        XCTAssertTrue(app.buttons["recipe.slot.3"].waitForExistence(timeout: 5), file: file, line: line)
        // Tap above the popover in the status region; native outside dismissal swallows it.
        let outside = app.buttons["app.status"].frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: outside.midX, dy: outside.midY)).tap()
        XCTAssertTrue(app.buttons["recipe.none"].waitForNonExistence(timeout: 3), file: file, line: line)
        XCTAssertEqual([app.staticTexts["fixture.viewed"].label, countLabel(app), app.staticTexts["fixture.exportCount"].label, control.label], before, file: file, line: line)
    }

    func openRecipeMenu(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let rect = app.buttons["recipe.control"].frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.midX, dy: rect.midY)).tap()
        XCTAssertTrue(app.buttons["recipe.none"].waitForExistence(timeout: 5), file: file, line: line)
    }

    func assertExportControlUsable(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let export = app.buttons["workspace.export"]
        XCTAssertTrue(export.exists, file: file, line: line)
        XCTAssertTrue(export.isEnabled, file: file, line: line)
        XCTAssertFalse(app.buttons["workspace.versions"].exists, file: file, line: line)
        // Screen taps exercise floating controls even when XCTest cannot find a hit point over letterboxing.
        let rect = export.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.midX, dy: rect.midY)).tap()
        XCTAssertEqual(app.staticTexts["fixture.exportCount"].label, "Export requests: 1", file: file, line: line)
    }

    func waitForDetent(_ app: XCUIApplication, expanded: Bool, file: StaticString = #filePath, line: UInt = #line) {
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

    func drawerTrace(_ app: XCUIApplication) -> [Double] {
        (app.otherElements["fixture.nativeMetrics"].value as? String ?? "").split(separator: ",").compactMap { Double($0) }
    }

    func assertTrajectory(_ values: [Double], opening: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let attachment = XCTAttachment(string: values.description); attachment.name = "Native grid top during drawer gesture"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertGreaterThan(values.count, 6, "Must observe actual intermediate native frames", file: file, line: line)
        for (previous, next) in zip(values, values.dropFirst()) {
            if opening { XCTAssertLessThanOrEqual(next, previous + 1.5, "Opening must not jump back down on release", file: file, line: line) }
            else { XCTAssertGreaterThanOrEqual(next, previous - 1.5, "Closing must not jump back up on release", file: file, line: line) }
        }
    }
}
