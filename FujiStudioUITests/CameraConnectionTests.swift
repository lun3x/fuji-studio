import XCTest

@MainActor
final class CameraConnectionTests: AppFlowTestCase {
    func testCameraMetadataErrorCanResetAndRenderAgainWithoutUnplugging() {
        let app = launch(["--fixture-camera-attention"])
        wait { app.buttons["app.status"].value as? String == "Camera ready" }
        app.cells["grid.source-0"].tap()
        recipe(1, in: app)
        wait { app.buttons["app.status"].value as? String == "Camera error" }
        XCTAssertTrue(app.scrollViews["viewer.image"].exists)
        XCTAssertNotEqual(app.buttons["recipe.control"].label, "No recipe selected")
        shot(app, "Red camera error status icon with retained photo")
        tap(app.buttons["app.status"], in: app)
        XCTAssertTrue(app.staticTexts["app.cameraError"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["app.cameraError"].label.contains("640 × 480"))
        shot(app, "Specific camera metadata error and reset action")
        app.buttons["app.resetCamera"].tap()
        wait { app.staticTexts["app.camera"].label.contains("ready for conversion") && !app.staticTexts["app.cameraError"].exists }
        app.buttons["Done"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].exists)
        XCTAssertNotEqual(app.buttons["recipe.control"].label, "No recipe selected")
        // A fresh recipe tap renders again using the reset connection.
        recipe(1, in: app)
        wait { app.scrollViews["viewer.image"].exists && !app.descendants(matching: .any)["viewer.status"].exists && app.buttons["workspace.export"].isEnabled }
        XCTAssertFalse(app.buttons["workspace.versions"].exists)
        XCTAssertEqual(app.buttons["app.status"].value as? String, "Camera ready")
        shot(app, "Camera preview after explicit reset")
    }

}
