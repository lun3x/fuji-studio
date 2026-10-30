import XCTest

@MainActor final class StatusSettingsTests: AppFlowTestCase {
    func testStatusContainsPersistentExportSetting() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixtures"]
        app.launchEnvironment["FUJI_STUDIO_SETTINGS_SUITE"] = "FujiSettingsUI-\(UUID())"
        app.launch()
        XCTAssertTrue(app.buttons["app.status"].waitForExistence(timeout: 10))
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.navigationBars["Status & settings"].waitForExistence(timeout: 5))
        let setting = app.switches["settings.updateOriginalInPhotos"]
        XCTAssertTrue(setting.waitForExistence(timeout: 5))
        if !setting.isHittable { app.swipeUp() }
        XCTAssertEqual(setting.value as? String, "0")
        XCTAssertTrue(app.staticTexts["settings.updateOriginalExplanation"].label.contains("Revert to Original"))
        setting.tap()
        XCTAssertEqual(setting.value as? String, "1")
        shot(app, "Status and settings with reversible export enabled")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["app.status"].waitForExistence(timeout: 10))
        app.buttons["app.status"].tap()
        XCTAssertTrue(setting.waitForExistence(timeout: 5))
        XCTAssertEqual(setting.value as? String, "1")
    }

    func testRepeatedOriginalUpdatesShowOnlyLatestInVersionPicker() {
        let app = launch()
        app.buttons["app.status"].tap()
        let setting = app.switches["settings.updateOriginalInPhotos"]
        XCTAssertTrue(setting.waitForExistence(timeout: 5))
        if !setting.isHittable { app.swipeUp() }
        setting.tap(); app.buttons["Done"].tap()
        app.cells["grid.source-0"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(3, in: app)
        wait { app.buttons["workspace.export"].isEnabled }
        app.buttons["workspace.export"].tap()
        wait { app.buttons["app.status"].label.contains("1 saved") }
        clearRecipe(in: app)
        app.buttons["workspace.versions"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "version.saved."))
        wait { saved.count == 1 }
        let first = saved.firstMatch.identifier
        app.buttons["version.cameraJPEG"].tap()
        recipe(2, in: app)
        wait { app.buttons["workspace.export"].isEnabled }
        app.buttons["workspace.export"].tap()
        wait { app.buttons["app.status"].label.contains("Warm shadows") && app.buttons["app.status"].label.contains("1 saved") }
        clearRecipe(in: app)
        app.buttons["workspace.versions"].tap()
        wait { saved.count == 1 && saved.firstMatch.identifier != first }
        XCTAssertFalse(app.buttons[first].exists)
        XCTAssertTrue(app.buttons["version.raw"].exists)
        XCTAssertTrue(app.buttons["version.cameraJPEG"].exists)
        shot(app, "Only latest reversible edit remains in version picker")
    }
}
