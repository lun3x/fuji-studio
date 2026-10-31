import XCTest

/// Shared fixture operations; concrete subclasses own all test methods.
@MainActor
class AppFlowTestCase: XCTestCase {
    func replaceText(_ field: XCUIElement, with value: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + value)
    }

    func reveal(_ element: XCUIElement, in app: XCUIApplication, towardsTop: Bool = false) {
        let form = app.descendants(matching: .any)["recipe.editor.form"].firstMatch
        let keyboard = app.keyboards.firstMatch
        if form.exists, keyboard.exists, keyboard.buttons["Return"].exists {
            app.typeText("\n")
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        }
        let container = form.exists ? form : app
        for reverse in [false, true] {
            for _ in 0..<16 {
                if element.exists {
                    let frame = element.frame
                    let viewport = container.frame.intersection(app.frame)
                    if element.isHittable,
                       viewport.insetBy(dx: 0, dy: 12).contains(CGPoint(x: frame.midX, y: frame.midY)) { return }
                    if !frame.isEmpty, frame.minY < container.frame.minY { container.swipeDown() }
                    else { container.swipeUp() }
                } else if towardsTop != reverse { container.swipeDown() }
                else { container.swipeUp() }
            }
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }

    func launch(_ flags: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixtures"] + flags; app.launch()
        XCTAssertTrue(app.buttons["workspace.select"].waitForExistence(timeout: 10))
        return app
    }

    func chooseAutoISO(in app: XCUIApplication) {
        let iso = app.buttons["recipe.editor.setting.iso"]
        reveal(iso, in: app);iso.tap();selectRecipeChoice("Auto 1", for: iso, in: app)
    }

    func selectRecipeChoice(_ value: String, for field: XCUIElement, in app: XCUIApplication) {
        let choice = app.buttons[value]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        wait { choice.isEnabled }
        if choice.isHittable {
            // Target the title column; selected titles follow a leading checkmark.
            let selected = field.label.hasSuffix(value) || field.value as? String == value
            choice.coordinate(withNormalizedOffset: CGVector(dx: selected ? 0.3 : 0.17, dy: 0.5))
                .press(forDuration: 0.15)
        } else {
            choice.press(forDuration: 0.15)
        }
        wait {
            (field.label.hasSuffix(value) || field.value as? String == value) && field.isHittable
        }
    }

    func saveRecipe(in app: XCUIApplication) {
        let save = app.buttons["recipe.editor.save"]
        // A native menu can still intercept taps while its selection animates.
        wait { save.isEnabled && save.isHittable }
        save.tap()
    }

    func tap(_ element: XCUIElement, in app: XCUIApplication) {
        let rect = element.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.midX, dy: rect.midY)).tap()
    }

    func recipe(_ slot: Int, in app: XCUIApplication) {
        tap(app.buttons["recipe.control"], in: app)
        XCTAssertTrue(app.buttons["recipe.slot.\(slot)"].waitForExistence(timeout: 5))
        tap(app.buttons["recipe.slot.\(slot)"], in: app)
    }

    func clearRecipe(in app: XCUIApplication) {
        tap(app.buttons["recipe.control"], in: app)
        XCTAssertTrue(app.buttons["recipe.none"].waitForExistence(timeout: 5))
        tap(app.buttons["recipe.none"], in: app)
    }

    func version(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        if app.buttons["workspace.versions"].exists { app.buttons["workspace.versions"].tap() }
        let button = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", identifier)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5)); return button
    }

    func wait(_ condition: @escaping () -> Bool) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 10), .completed)
    }

    func shot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let export = app.buttons["workspace.export"]
        let bounds = XCTAttachment(string: "Status \(app.buttons["app.status"].frame); Recipe \(app.buttons["recipe.control"].frame); Export \(export.exists ? String(describing: export.frame) : "hidden"); Grid \(app.collectionViews["photoGrid"].frame)")
        bounds.name = name + " bounds"; bounds.lifetime = .keepAlways; add(bounds)
    }

    func selectFirstRow(_ app: XCUIApplication) {
        app.buttons["workspace.select"].tap()
        app.cells["grid.source-0"].tap() // Clear the viewed seed before an additive sweep.
        let start = app.cells["grid.source-0"].coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.65))
        let end = app.cells["grid.source-2"].coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.65))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    func assertFloatingPhotoControls(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let status = app.buttons["app.status"], recipe = app.buttons["recipe.control"], versions = app.buttons["workspace.versions"]
        let viewer = app.scrollViews["viewer.image"]
        for control in [status, recipe, versions] {
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, file: file, line: line)
            XCTAssertGreaterThanOrEqual(control.frame.width, 44, file: file, line: line)
            XCTAssertEqual(control.frame.minY, status.frame.minY, accuracy: 1, file: file, line: line)
            XCTAssertGreaterThanOrEqual(control.frame.minY, viewer.frame.minY, file: file, line: line)
            XCTAssertLessThanOrEqual(control.frame.maxY, viewer.frame.maxY, file: file, line: line)
            XCTAssertGreaterThanOrEqual(control.frame.minX, app.frame.minX, file: file, line: line)
            XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX, file: file, line: line)
        }
        XCTAssertEqual(status.frame.minX, viewer.frame.minX + 16, accuracy: 1, file: file, line: line)
        XCTAssertEqual(status.frame.minY, viewer.frame.minY + 8, accuracy: 1, file: file, line: line)
        XCTAssertEqual(versions.frame.maxX, viewer.frame.maxX - 16, accuracy: 1, file: file, line: line)
        XCTAssertEqual(recipe.frame.maxX + 8, versions.frame.minX, accuracy: 1, file: file, line: line)
        XCTAssertFalse(app.buttons["app.connect"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["workspace.export"].exists, file: file, line: line)
        XCTAssertFalse(app.staticTexts["Fuji Studio"].exists, file: file, line: line)
    }

    func backgroundFlow(native: Bool) {
        let app = launch(["--fixture-held-save"] + (native ? [] : ["--fixture-scene-controls"]))
        app.cells["grid.source-0"].tap(); wait { app.buttons["app.status"].label.contains("Camera ready") }
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(3, in: app)
        selectFirstRow(app)
        wait { app.staticTexts["workspace.count"].label == "3 selected" }
        app.buttons["workspace.export"].tap()
        wait { app.buttons["app.status"].label.contains("Saving to Photos") }
        if native {
            XCUIDevice.shared.press(.home)
            let reachedBackground = app.wait(for: .runningBackground, timeout: 5)
            let boundary = XCTAttachment(string: "Reached background: \(reachedBackground), application state: \(app.state.rawValue), at \(Date.timeIntervalSinceReferenceDate)")
            boundary.name = "Public background boundary"; boundary.lifetime = .keepAlways; add(boundary)
            app.activate()
            shot(app, "Actual scene state after Home and activate")
            guard reachedBackground else { XCTFail("Home did not produce a background application state"); return }
        } else {
            app.buttons["fixture.background"].tap()
            app.buttons["fixture.foreground"].tap()
        }
        XCTAssertTrue(app.buttons["fixture.finishSave"].waitForExistence(timeout: 5))
        app.buttons["fixture.finishSave"].tap()
        wait { app.buttons["app.status"].label.contains("Export paused") }
        XCTAssertFalse((app.buttons["app.status"].value as? String)?.contains("Exporting") == true)
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.staticTexts["export.counts"].label.contains("1 saved"))
        XCTAssertTrue(app.staticTexts["export.counts"].label.contains("2 remaining"))
        wait { app.buttons["export.resume"].isEnabled }
        shot(app, native ? "Paused after verified native background" : "Paused after injected scene callbacks")
        app.buttons["export.resume"].tap()
        wait { app.staticTexts["export.counts"].label.contains("3 saved") }
        XCTAssertEqual(app.staticTexts["export.status"].label, "Export saved")
    }
}
