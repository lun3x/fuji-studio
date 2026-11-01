import XCTest

@MainActor final class BatchPairRemovalTests: AppFlowTestCase {
    func testMultiRAWExportKeepsAwakeAtFinalConfirmationAndFinishesWithoutResume() {
        let app = launch(["--fixture-raw-only-batch", "--fixture-held-cleanup", "--fixture-scene-controls"])
        app.buttons["app.status"].tap()
        let setting = app.switches["settings.updateOriginalInPhotos"]
        XCTAssertTrue(setting.waitForExistence(timeout: 5))
        if !setting.isHittable { app.swipeUp() }
        setting.tap(); app.buttons["Done"].tap()
        app.cells["grid.source-0"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        app.buttons["workspace.select"].tap()
        app.cells["grid.source-1"].tap(); app.cells["grid.source-2"].tap()
        recipe(3, in: app)
        wait { app.buttons["workspace.export"].isEnabled }
        app.buttons["workspace.export"].tap()
        app.buttons["app.status"].tap()
        wait { app.staticTexts["export.counts"].label.contains("0 remaining") && app.staticTexts["export.counts"].label.contains("3 awaiting cleanup") }
        XCTAssertTrue(app.staticTexts["export.counts"].label.contains("0 unconfirmed"))
        XCTAssertTrue((app.progressIndicators["export.progress"].value as? String ?? "").contains("3 of 3 processed"))
        shot(app, "Verified exports show full progress before original cleanup")
        app.buttons["Done"].tap()
        XCTAssertTrue((app.buttons["app.status"].value as? String ?? "").contains("3 of 3 processed"))
        XCTAssertTrue(app.buttons["app.status"].label.contains("3 exported"))
        app.buttons["fixture.inactive"].tap()
        XCTAssertEqual(app.buttons["fixture.finishSave"].value as? String, "Awake")
        app.buttons["fixture.finishSave"].tap()
        wait { app.buttons["app.status"].label.contains("3 saved") }
        app.buttons["fixture.foreground"].tap()
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.staticTexts["export.counts"].label.contains("0 unconfirmed"))
        XCTAssertFalse(app.buttons["export.resume"].exists)
        shot(app, "Three RAW pairs finish after one final cleanup confirmation")
    }
}
