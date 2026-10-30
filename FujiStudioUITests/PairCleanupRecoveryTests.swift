import XCTest

@MainActor final class PairCleanupRecoveryTests: AppFlowTestCase {
    func testStatusOffersExplicitCompletionForAnAlreadySavedPair() {
        let app = launch(["--fixture-pair-cleanup-pending"])
        app.buttons["app.status"].tap()
        let setting = app.switches["settings.updateOriginalInPhotos"]
        XCTAssertTrue(setting.waitForExistence(timeout: 5))
        if !setting.isHittable { app.swipeUp() }
        setting.tap(); app.buttons["Done"].tap()
        app.cells["grid.source-1"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        app.buttons["workspace.select"].tap()
        recipe(3, in: app)
        wait { app.buttons["workspace.export"].isEnabled }
        app.buttons["workspace.export"].tap()
        wait { app.buttons["app.status"].label.contains("removal pending") }
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.buttons["export.finishReplacement"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["export.finishReplacement"].isEnabled)
        app.buttons["export.reconcile"].tap()
        wait { app.staticTexts["export.counts"].label.contains("1 unconfirmed") }
        app.buttons["export.finishReplacement"].tap()
        wait { app.staticTexts["export.counts"].label.contains("1 saved") && app.staticTexts["export.counts"].label.contains("0 unconfirmed") }
        XCTAssertFalse(app.buttons["export.finishReplacement"].exists)
        shot(app, "Finish replacement confirms the existing pair without another export")
    }
}
