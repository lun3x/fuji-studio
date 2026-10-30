import XCTest

@MainActor
final class ModelRecipeTests: AppFlowTestCase {
    func testXE3RAWDisplayFailureKeepsPairedJPEGAndConversionAvailable() {
        let app=launch(["--fixture-xe3","--fixture-raw-unavailable"])
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        app.cells["grid.source-0"].tap()
        tap(app.buttons["workspace.versions"],in:app);app.buttons["version.raw"].tap()
        let unavailable=app.descendants(matching:.any)["viewer.unavailable"]
        XCTAssertTrue(unavailable.waitForExistence(timeout:5))
        XCTAssertTrue(unavailable.label.contains("Camera conversion is still available"))
        shot(app,"X-E3 RAW unavailable with explicit JPEG choice")
        tap(app.buttons["workspace.versions"],in:app);app.buttons["version.cameraJPEG"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout:5))
        recipe(4,in:app);wait { app.buttons["workspace.export"].isEnabled }
        app.buttons["workspace.export"].tap()
        wait { app.buttons["app.status"].label.contains("1 saved") }
        tap(app.buttons["recipe.control"],in:app);app.buttons["recipe.none"].tap()
        tap(app.buttons["workspace.versions"],in:app)
        let saved=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","version.saved.")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout:5));saved.tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout:5))
        shot(app,"X-E3 conversion and saved version after RAW decoder failure")
    }

    func testXE3EditorAtLargestTextRemainsUsableInLandscape() {
        let app=launch(["--fixture-xe3","--fixture-accessibility"])
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["recipe.control"],in:app);app.buttons["recipe.copy.1"].tap()
        let edit=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","recipe.edit.")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout:5));edit.tap()
        XCTAssertTrue(app.buttons["recipe.editor.save"].waitForExistence(timeout:5))
        chooseAutoISO(in:app)
        shot(app,"X-E3 editor largest text portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        wait {
            let window=app.windows.firstMatch.frame,save=app.buttons["recipe.editor.save"].frame
            return window.width > window.height && save.maxX > window.width/2 && save.maxX <= window.maxX
        }
        XCTAssertTrue(app.buttons["recipe.editor.save"].isHittable)
        XCTAssertTrue(app.buttons["recipe.editor.cancel"].isHittable)
        let landscape=XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        landscape.name="X-E3 editor largest text landscape full screen";landscape.lifetime = .keepAlways;add(landscape)
        app.buttons["recipe.editor.cancel"].tap()
    }

    func testXE3EditorUsesCameraCapabilitiesAndDiscreteKelvin() {
        let app=launch(["--fixture-xe3"])
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["recipe.control"],in:app);app.buttons["recipe.copy.4"].tap()
        let edit=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","recipe.edit.")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout:5));edit.tap()
        let grain=app.buttons["recipe.editor.setting.grainEffect"]
        XCTAssertTrue(grain.waitForExistence(timeout:5))
        let size=app.buttons["recipe.editor.setting.grainSize"]
        reveal(size,in:app);XCTAssertTrue(size.exists);XCTAssertFalse(size.isEnabled)
        let chrome=app.buttons["recipe.editor.setting.colorChrome"]
        reveal(chrome,in:app);XCTAssertTrue(chrome.exists);XCTAssertFalse(chrome.isEnabled)
        let clarity=app.buttons["recipe.editor.setting.clarity"]
        reveal(clarity,in:app);XCTAssertTrue(clarity.exists);XCTAssertFalse(clarity.isEnabled)
        let kelvin=app.buttons["recipe.editor.setting.kelvin"]
        reveal(kelvin,in:app,towardsTop:true);kelvin.tap()
        let search=app.textFields["recipe.editor.temperature.search"]
        XCTAssertTrue(search.waitForExistence(timeout:5));search.tap();search.typeText("7100")
        app.buttons["7100"].tap()
        chooseAutoISO(in:app)
        shot(app,"X-E3 semantic editor and verified Kelvin")
        app.buttons["recipe.editor.save"].tap()
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout:5))
        edit.tap();reveal(kelvin,in:app)
        XCTAssertEqual(app.textFields["recipe.editor.temperature"].value as? String,"7100")
        app.buttons["recipe.editor.cancel"].tap()
    }

    func testDeclaredThreeSlotsHaveNoInventedExtraRows() {
        let app=launch(["--fixture-xe3","--fixture-three-slots"])
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["recipe.control"],in:app)
        for slot in 1...3 { XCTAssertTrue(app.buttons["recipe.slot.\(slot)"].exists) }
        for slot in 4...7 { XCTAssertFalse(app.buttons["recipe.slot.\(slot)"].exists) }
        shot(app,"Three declared recipe slots")
    }

    func testOtherModelPhoneRecipeStaysVisibleAndEditable() {
        let app=launch(["--fixture-xe3","--fixture-mixed-models"])
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["recipe.control"],in:app)
        app.segmentedControls["recipe.collection"].buttons["Phone"].tap()
        let phone=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","recipe.phone.")).firstMatch
        XCTAssertTrue(phone.exists);XCTAssertFalse(phone.isEnabled)
        XCTAssertTrue(phone.label.contains("X-T5"))
        let edit=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","recipe.edit.")).firstMatch
        XCTAssertTrue(edit.isEnabled);edit.tap()
        XCTAssertTrue(app.textFields["recipe.editor.name"].waitForExistence(timeout:5))
        replaceText(app.textFields["recipe.editor.name"],with:"Other model offline edit")
        app.buttons["recipe.editor.save"].tap()
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout:5))
        XCTAssertTrue(phone.label.contains("Other model offline edit"));XCTAssertFalse(phone.isEnabled)
        shot(app,"Other Fujifilm model remains editable")
    }
}
