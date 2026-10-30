import XCTest

@MainActor
final class WorkspaceLayoutTests: WorkspaceTestCase {
    func testDayCheckboxAvoidsTrayControlsAndCollapsedTrayShowsFullPhotoRow() {
        let app = launch(["--fixture-dated-photos"])
        let day = app.buttons["grid.day.2026-10-23"]
        XCTAssertTrue(day.waitForExistence(timeout: 5))
        XCTAssertFalse(day.frame.intersects(app.buttons["workspace.select"].frame))
        let grid = app.collectionViews["photoGrid"].frame
        let first = app.cells["grid.source-0"].frame
        XCTAssertGreaterThanOrEqual(first.minY, grid.minY)
        XCTAssertLessThanOrEqual(first.maxY, grid.maxY - 34 + 1)
        day.tap()
        XCTAssertEqual(app.staticTexts["workspace.count"].label, "6 selected")
        XCTAssertEqual(day.value as? String, "Checked")
        XCTAssertFalse(app.staticTexts["Fri, Oct 23, 2026"].frame.intersects(app.staticTexts["workspace.count"].frame))
        shot(app, "Workspace day divider and selection controls")
    }
    func testRecipeRowsRespondToBlankPadding() {
        let app = launch()
        openRecipeMenu(app)
        // Selection padding ends before the separate copy button.
        let cameraRow = app.buttons["recipe.slot.2"]
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: cameraRow.frame.maxX - 6, dy: cameraRow.frame.midY)).tap()
        XCTAssertTrue(app.buttons["recipe.none"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["recipe.control"].label.contains("C2"))
        openRecipeMenu(app)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.scrollViews["recipe.options"].frame.maxX - 6, dy: app.buttons["recipe.none"].frame.midY)).tap()
        XCTAssertTrue(app.buttons["recipe.none"].waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.buttons["recipe.control"].label, "No recipe selected")
        XCTAssertFalse(app.buttons["workspace.export"].exists)
    }

    func testCopyButtonIncludesTrailingPaddingWithoutSelectingRecipe() {
        let app = launch()
        openRecipeMenu(app)
        let previous = app.buttons["recipe.control"].label
        let copy = app.buttons["recipe.copy.2"]
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: app.scrollViews["recipe.options"].frame.maxX - 6, dy: copy.frame.midY)).tap()
        let phone = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.phone.")).firstMatch
        XCTAssertTrue(phone.waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["recipe.collection"].buttons["Phone"].isSelected)
        XCTAssertEqual(app.buttons["recipe.control"].label, previous)
        XCTAssertFalse(phone.isSelected)
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
        XCTAssertTrue(app.buttons["recipe.slot.7"].label.contains("Conversion is unavailable"))

        // Stay inside the app's safe area; a screen-relative point can hit the system status bar.
        shot(app, "Recipe C3 native popover")
        let outside = app.buttons["app.status"].frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: outside.midX, dy: outside.midY)).tap()
        XCTAssertTrue(app.buttons["recipe.none"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["recipe.control"].label.contains("C3"))
        openRecipeMenu(app)
        app.buttons["recipe.none"].tap()

        XCTAssertEqual(app.buttons["recipe.control"].label, "No recipe selected")
        XCTAssertFalse(app.buttons["workspace.export"].exists)
        openRecipeMenu(app)
        app.buttons["recipe.slot.3"].tap()
        XCTAssertTrue(app.buttons["workspace.export"].isEnabled)
        app.buttons["workspace.export"].tap()
        XCTAssertEqual(app.staticTexts["fixture.exportCount"].label, "Export requests: 1")
        XCTAssertFalse(app.buttons["workspace.versions"].exists)
        openRecipeMenu(app)
        app.buttons["recipe.none"].tap()
        app.buttons["workspace.versions"].tap()
        XCTAssertTrue(app.buttons["version.cameraJPEG"].isSelected)
        app.buttons["version.cameraJPEG"].tap()
        openRecipeMenu(app)
        app.buttons["recipe.slot.3"].tap()
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
        XCTAssertFalse(app.buttons["recipe.slot.7"].isEnabled)
        XCTAssertTrue(app.buttons["recipe.copy.7"].isEnabled)
        app.buttons["recipe.none"].tap()
        XCTAssertEqual(app.buttons["recipe.control"].label,"No recipe selected")
        XCTAssertFalse(app.buttons["workspace.export"].exists)

    }
}
