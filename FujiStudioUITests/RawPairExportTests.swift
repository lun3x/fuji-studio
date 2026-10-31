import XCTest

@MainActor final class RawPairExportTests: AppFlowTestCase {
    func testRAWOnlyExportCreatesCheckedPairAndLaterExportEditsThatSamePair() {
        let app = launch()
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
        wait { app.buttons["app.status"].label.contains("1 saved") }

        let pairedCells = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "grid.fixture-pair-"))
        XCTAssertTrue(pairedCells.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(pairedCells.count, 1)
        let pair = pairedCells.firstMatch, pairID = pair.identifier
        XCTAssertFalse(app.cells["grid.source-1"].exists)
        XCTAssertEqual(pair.value as? String, "Checked")
        XCTAssertEqual(app.staticTexts["workspace.count"].label, "1 selected")
        clearRecipe(in: app)
        app.buttons["workspace.versions"].tap()
        XCTAssertTrue(app.buttons["version.raw"].exists)
        wait { app.buttons["version.cameraJPEG"].label.contains("Paired JPEG") }
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "version.saved."))
        XCTAssertEqual(saved.count, 0)
        shot(app, "RAW-only source becomes a selected RAW and JPEG pair")
        app.buttons["version.cameraJPEG"].tap()

        recipe(2, in: app)
        wait { app.buttons["workspace.export"].isEnabled }
        app.buttons["workspace.export"].tap()
        wait { app.buttons["app.status"].label.contains("Warm shadows") && app.buttons["app.status"].label.contains("1 saved") }
        XCTAssertEqual(pairedCells.count, 1)
        XCTAssertEqual(pairedCells.firstMatch.identifier, pairID)
        XCTAssertEqual(pair.value as? String, "Checked")
        clearRecipe(in: app)
        app.buttons["workspace.versions"].tap()
        XCTAssertTrue(app.buttons["version.raw"].exists)
        XCTAssertTrue(app.buttons["version.cameraJPEG"].exists)
        wait { saved.count == 1 }
        shot(app, "Later export edits the same pair and retains both originals")
    }
}
