import XCTest

@MainActor
final class PhoneRecipeLibraryTests: AppFlowTestCase {
    func testOfflineCameraCopyAppearsOnPhoneButRequiresCameraForSelection() {
        let app = launch(["--fixture-disconnected-camera"])
        app.cells["grid.source-0"].tap()
        tap(app.buttons["recipe.control"], in: app)
        let tabs = app.segmentedControls["recipe.collection"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        tabs.buttons["Phone"].tap()
        XCTAssertTrue(app.staticTexts["recipe.phone.empty"].waitForExistence(timeout: 5))
        shot(app, "Phone recipes empty state")
        tabs.buttons["Camera"].tap()
        let copy = app.buttons["recipe.copy.3"]
        XCTAssertTrue(copy.isEnabled, "Copying cached recipes works offline")
        XCTAssertFalse(app.buttons["recipe.slot.3"].isEnabled)
        copy.tap()
        let phone = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.phone.")).firstMatch
        XCTAssertTrue(phone.waitForExistence(timeout: 5))
        XCTAssertTrue(tabs.buttons["Phone"].isSelected)
        XCTAssertFalse(phone.isSelected)
        XCTAssertTrue(app.buttons["recipe.none"].isSelected)
        XCTAssertEqual(app.buttons["recipe.control"].label, "No recipe selected")
        shot(app, "Camera recipe saved on phone without changing selection")
        tabs.buttons["Camera"].tap()
        copy.tap()
        XCTAssertTrue(phone.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.phone.")).count, 1)
        XCTAssertFalse(phone.isEnabled)
        tap(app.buttons["recipe.none"], in: app)
        app.buttons["fixture.plugInCamera"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["recipe.control"], in: app)
        tabs.buttons["Phone"].tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.phone.")).count, 1)
        XCTAssertTrue(phone.isEnabled)
        phone.tap()
        XCTAssertTrue(app.buttons["workspace.export"].waitForExistence(timeout: 5))
        wait { app.buttons["workspace.export"].isEnabled }
        shot(app, "Saved phone recipe selected with camera ready")
    }

    func testPhoneRecipeCopyAndDeletionAtLargestText() {
        let app = launch(["--fixture-accessibility", "--fixture-disconnected-camera"])
        tap(app.buttons["recipe.control"], in: app)
        let copy = app.buttons["recipe.copy.1"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(copy.frame.width, 44)
        XCTAssertGreaterThanOrEqual(copy.frame.height, 44)
        shot(app, "Camera recipe copy controls at largest text")
        copy.tap()
        let phone = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.phone.")).firstMatch
        XCTAssertTrue(phone.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(phone.frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["recipe.none"].frame.minY, app.scrollViews["recipe.options"].frame.minY,
            "Switching collections starts at the top even after the camera list scrolls")
        shot(app, "Phone recipe at largest text")
        XCTAssertFalse(phone.isEnabled)
        let delete = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.delete.")).firstMatch
        XCTAssertTrue(delete.isEnabled)
        XCTAssertGreaterThanOrEqual(delete.frame.width, 44)
        XCTAssertGreaterThanOrEqual(delete.frame.height, 44)
        delete.tap()
        XCTAssertTrue(app.alerts["Delete phone recipe?"].waitForExistence(timeout: 5))
        shot(app, "Phone recipe delete confirmation at largest text")
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["recipe.phone.empty"].waitForExistence(timeout: 5))
    }

    func testOfflinePhoneDeletionCanBeCancelledConfirmedAndRecopied() {
        let app = launch(["--fixture-disconnected-camera"])
        tap(app.buttons["recipe.control"], in: app)
        app.buttons["recipe.copy.3"].tap()
        let phoneQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.phone."))
        XCTAssertTrue(phoneQuery.firstMatch.waitForExistence(timeout: 5))
        let originalIdentifier = phoneQuery.firstMatch.identifier
        XCTAssertFalse(phoneQuery.firstMatch.isEnabled)
        let delete = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.delete.")).firstMatch
        XCTAssertTrue(delete.isEnabled)
        shot(app, "Disconnected phone recipe greyed with delete enabled")
        delete.tap()
        XCTAssertTrue(app.alerts["Delete phone recipe?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons[originalIdentifier].exists)
        delete.tap()
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons[originalIdentifier].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["recipe.phone.empty"].exists)
        XCTAssertTrue(app.buttons["recipe.none"].isSelected)
        app.segmentedControls["recipe.collection"].buttons["Camera"].tap()
        app.buttons["recipe.copy.3"].tap()
        XCTAssertTrue(phoneQuery.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(phoneQuery.firstMatch.identifier, originalIdentifier)
        XCTAssertEqual(phoneQuery.count, 1)
    }

    func testDeletingSelectedPhoneRecipeClearsSelectionAndRestoresVersionsControl() {
        let app = launch()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        app.cells["grid.source-0"].tap()
        tap(app.buttons["recipe.control"], in: app)
        app.buttons["recipe.copy.3"].tap()
        let phone = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.phone.")).firstMatch
        XCTAssertTrue(phone.waitForExistence(timeout: 5))
        phone.tap()
        wait { app.buttons["workspace.export"].isEnabled }
        tap(app.buttons["recipe.control"], in: app)
        XCTAssertTrue(app.segmentedControls["recipe.collection"].buttons["Phone"].isSelected)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.delete.")).firstMatch.tap()
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["recipe.phone.empty"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["recipe.none"].isSelected)
        XCTAssertEqual(app.buttons["recipe.control"].label, "No recipe selected")
        XCTAssertFalse(app.buttons["workspace.export"].exists)
        XCTAssertTrue(app.buttons["workspace.versions"].exists)
        shot(app, "Deleting selected phone recipe restores versions")
    }
}
