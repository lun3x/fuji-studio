import XCTest

@MainActor
final class RecipePhotoCompatibilityTests: AppFlowTestCase {
    func testXT5RecipesAreDisabledForMixedPhotoSelection() {
        assertRecipesDisabledForMixedPhotoSelection(flags: [])
    }

    func testXE3RecipesAreDisabledForMixedPhotoSelection() {
        assertRecipesDisabledForMixedPhotoSelection(flags: ["--fixture-xe3"])
    }

    private func assertRecipesDisabledForMixedPhotoSelection(flags: [String]) {
        let app = launch(flags + ["--fixture-filter-sources"])
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        // Assess all three originals, including the wrong model and unsupported geometry.
        tap(app.buttons["workspace.filter"], in: app); app.buttons["filter.compatible"].tap()
        wait {
            app.cells["grid.source-0"].exists && !app.staticTexts["filter.progress"].exists &&
                !app.cells["grid.source-1"].exists && !app.cells["grid.source-2"].exists
        }
        tap(app.buttons["workspace.filter"], in: app); app.buttons["filter.all"].tap()
        for incompatibleID in ["source-1", "source-2"] {
            app.cells["grid.\(incompatibleID)"].tap()
            app.buttons["workspace.select"].tap()
            app.cells["grid.source-0"].tap()
            wait { app.staticTexts["workspace.count"].label == "2 selected" }
            tap(app.buttons["recipe.control"], in: app)
            for slot in 1...7 { XCTAssertFalse(app.buttons["recipe.slot.\(slot)"].isEnabled) }
            XCTAssertTrue(app.buttons["recipe.none"].isEnabled)
            XCTAssertTrue(app.buttons["recipe.refresh"].isEnabled)
            shot(app, "Camera recipes disabled for \(incompatibleID) in mixed selection")
            let copy = app.buttons["recipe.copy.3"]
            XCTAssertTrue(copy.isEnabled)
            reveal(copy, in: app); copy.tap()
            let phone = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.phone.")).firstMatch
            XCTAssertTrue(phone.waitForExistence(timeout: 5))
            XCTAssertFalse(phone.isEnabled)
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.edit.")).firstMatch.isEnabled)
            shot(app, "Recipes disabled for \(incompatibleID) in mixed selection")
            tap(app.buttons["recipe.none"], in: app)
            app.cells["grid.\(incompatibleID)"].tap()
            wait { app.staticTexts["workspace.count"].label == "1 selected" }
            tap(app.buttons["recipe.control"], in: app)
            for slot in 1...6 { XCTAssertTrue(app.buttons["recipe.slot.\(slot)"].isEnabled) }
            app.segmentedControls["recipe.collection"].buttons["Phone"].tap()
            XCTAssertTrue(phone.isEnabled)
            tap(app.buttons["recipe.none"], in: app)
            app.buttons["workspace.select"].tap()
        }
    }
}
