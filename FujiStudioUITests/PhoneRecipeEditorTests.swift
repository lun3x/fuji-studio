import XCTest

@MainActor
final class PhoneRecipeEditorTests: AppFlowTestCase {
    func testExistingASTIAPhoneRecipeCanBeAppliedWithoutChangingItsFilm() {
        let app = launch(["--fixture-astia-film"])
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        app.cells["grid.source-0"].tap()
        tap(app.buttons["recipe.control"], in: app); app.buttons["recipe.copy.4"].tap()
        let phone = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.phone.")).firstMatch
        XCTAssertTrue(phone.waitForExistence(timeout: 5)); XCTAssertTrue(phone.isEnabled)
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.edit.")).firstMatch
        edit.tap()
        let film = app.buttons["recipe.editor.setting.film"]
        XCTAssertTrue(film.label.contains("ASTIA"))
        XCTAssertFalse(film.label.contains("unavailable for conversion"))
        shot(app, "Existing ASTIA recipe remains supported without editing its film")
        saveRecipe(in: app)
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(phone.isEnabled)
        phone.tap()
        wait { app.buttons["workspace.export"].isEnabled }
        shot(app, "Existing ASTIA phone recipe is available for conversion")
    }

    func testPhoneEditorGrainChoicesSurviveSaveAndReopen() {
        let app = launch(["--fixture-disconnected-camera"])
        tap(app.buttons["recipe.control"], in: app); app.buttons["recipe.copy.3"].tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.edit.")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        let effect = app.buttons["recipe.editor.setting.grainEffect"]
        let size = app.buttons["recipe.editor.setting.grainSize"]
        XCTAssertTrue(effect.waitForExistence(timeout: 5))
        reveal(effect, in: app); effect.tap()
        XCTAssertTrue(app.buttons["Weak"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Weak"].isEnabled)
        selectRecipeChoice("Off", for: effect, in: app)
        XCTAssertTrue(size.waitForNonExistence(timeout: 5))
        effect.tap(); selectRecipeChoice("Strong", for: effect, in: app)
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        XCTAssertTrue(size.isEnabled)
        size.tap()
        XCTAssertTrue(app.buttons["Large"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Large"].isEnabled)
        selectRecipeChoice("Small", for: size, in: app)
        shot(app, "Convertible X-T5 grain choices")
        saveRecipe(in: app)
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(effect.label.contains("Strong")); XCTAssertTrue(size.label.contains("Small"))
        effect.tap(); selectRecipeChoice("Off", for: effect, in: app); saveRecipe(in: app)
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(effect.label.contains("Off")); XCTAssertFalse(size.exists)
        app.buttons["recipe.editor.cancel"].tap()
    }

    func testPhoneEditorSavesNameAndFilmOfflineAndCancelDiscardsChanges() {
        let app = launch(["--fixture-disconnected-camera"])
        tap(app.buttons["recipe.control"], in: app); app.buttons["recipe.copy.3"].tap()
        let phoneQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.phone."))
        XCTAssertTrue(phoneQuery.firstMatch.waitForExistence(timeout: 5))
        let id = phoneQuery.firstMatch.identifier
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.edit.")).firstMatch
        XCTAssertTrue(edit.isEnabled); XCTAssertFalse(phoneQuery.firstMatch.isEnabled)
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForExistence(timeout: 5))
        app.textFields["recipe.editor.name"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        reveal(app.buttons["recipe.editor.setting.film"], in: app)
        let film = app.buttons["recipe.editor.setting.film"]
        film.tap()
        // Exercise film persistence with an option visible beside the current Classic Chrome choice.
        selectRecipeChoice("ACROS", for: film, in: app)
        replaceText(app.textFields["recipe.editor.name"], with: "My ACROS")
        shot(app, "Phone editor name and film draft")
        saveRecipe(in: app)
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons[id].label.contains("My ACROS"))
        XCTAssertFalse(app.buttons[id].isEnabled)
        edit.tap()
        XCTAssertEqual(app.textFields["recipe.editor.name"].value as? String, "My ACROS")
        XCTAssertTrue(film.label.contains("ACROS") || (film.value as? String ?? "").contains("ACROS"))
        replaceText(app.textFields["recipe.editor.name"], with: "Discard me")
        app.buttons["recipe.editor.cancel"].tap()
        XCTAssertTrue(app.buttons[id].label.contains("My ACROS"))
        XCTAssertEqual(phoneQuery.count, 1)
    }

    func testPhoneEditorNumericPickerDescendsThroughFractionalAndNegativeValues() {
        let app = launch(["--fixture-disconnected-camera"])
        tap(app.buttons["recipe.control"], in: app); app.buttons["recipe.copy.3"].tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.edit.")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        app.textFields["recipe.editor.name"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let highlights = app.buttons["recipe.editor.setting.highlight"]
        reveal(highlights, in: app); highlights.tap()
        let labels = ["+4", "+3.5", "+3", "+2.5", "+2", "+1.5", "+1", "+0.5", "0", "-0.5", "-1", "-1.5", "-2"]
        XCTAssertTrue(app.buttons[labels[0]].waitForExistence(timeout: 5))
        for (upper, lower) in zip(labels, labels.dropFirst()) {
            XCTAssertLessThan(app.buttons[upper].frame.minY, app.buttons[lower].frame.minY)
        }
        shot(app, "Highlights descend from positive through zero to negative")
        selectRecipeChoice("+3.5", for: highlights, in: app)
        saveRecipe(in: app)
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout: 5))
        edit.tap(); reveal(highlights, in: app)
        XCTAssertTrue(highlights.label.contains("+3.5"))
        app.buttons["recipe.editor.cancel"].tap()
    }

    func testPhoneEditorRejectsInvalidTemperatureAndKeepsDraft() {
        let app = launch(["--fixture-disconnected-camera"])
        tap(app.buttons["recipe.control"], in: app); app.buttons["recipe.copy.3"].tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.edit.")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        app.textFields["recipe.editor.name"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let balance = app.buttons["recipe.editor.setting.whiteBalance"]
        reveal(balance, in: app); balance.tap()
        selectRecipeChoice("Colour temperature", for: balance, in: app)
        let temperature = app.textFields["recipe.editor.temperature"]
        reveal(temperature, in: app); replaceText(temperature, with: "10001")
        XCTAssertTrue(app.images["recipe.editor.temperature.unavailable"].exists)
        shot(app, "Phone editor temperature draft before validation")
        XCTAssertFalse(app.buttons["recipe.editor.save"].isEnabled)
        XCTAssertEqual(temperature.value as? String, "10001")
        replaceText(temperature, with: "5200")
        saveRecipe(in: app)
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout: 5))
        edit.tap(); reveal(app.buttons["recipe.editor.setting.whiteBalance"], in: app)
        XCTAssertEqual(app.textFields["recipe.editor.temperature"].value as? String, "5200")
    }

    func testPhoneEditorAtLargestTextHasUsableSaveAndCancel() {
        let app = launch(["--fixture-disconnected-camera", "--fixture-accessibility"])
        tap(app.buttons["recipe.control"], in: app); app.buttons["recipe.copy.1"].tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.edit.")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); XCTAssertGreaterThanOrEqual(edit.frame.width, 44)
        edit.tap(); XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.textFields["recipe.editor.name"].frame.height, 44,
                             "The editor must inherit the largest accessibility text size")
        let effect = app.buttons["recipe.editor.setting.grainEffect"]
        reveal(effect, in: app); effect.tap(); selectRecipeChoice("Off", for: effect, in: app)
        let size = app.buttons["recipe.editor.setting.grainSize"]
        XCTAssertTrue(size.waitForNonExistence(timeout: 5))
        shot(app, "Phone editor at largest text")
        XCTAssertTrue(app.buttons["recipe.editor.save"].isHittable)
        XCTAssertTrue(app.buttons["recipe.editor.cancel"].isHittable)
        app.buttons["recipe.editor.cancel"].tap()
    }

    func testXT5EditorOffersCameraSupportedFilmRangeAndBalance() throws {
        let app = launch()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        app.cells["grid.source-0"].tap()
        tap(app.buttons["recipe.control"], in: app); app.buttons["recipe.copy.1"].tap()
        let phone = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.phone.")).firstMatch
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.edit.")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        let film = app.buttons["recipe.editor.setting.film"]
        // Settle and dismiss the Name keyboard before a late presentation can cover a picker.
        let name = app.textFields["recipe.editor.name"]
        let originalName = try XCTUnwrap(name.value as? String)
        name.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        reveal(film, in: app)
        XCTAssertEqual(name.value as? String, originalName)
        film.tap()
        selectRecipeChoice("ASTIA / Soft", for: film, in: app)
        let dynamicRange = app.buttons["recipe.editor.setting.dynamicRange"]
        dynamicRange.tap()
        XCTAssertTrue(app.buttons["200%"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Auto"].isEnabled)
        selectRecipeChoice("200%", for: dynamicRange, in: app)
        let balance = app.buttons["recipe.editor.setting.whiteBalance"]
        reveal(balance, in: app); balance.tap()
        XCTAssertTrue(app.buttons["Daylight"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Daylight"].isEnabled)
        XCTAssertTrue(app.buttons["Custom 3"].isEnabled)
        selectRecipeChoice("Colour temperature", for: balance, in: app)
        saveRecipe(in: app)
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(phone.isEnabled)
        edit.tap()
        XCTAssertTrue(film.label.contains("ASTIA"))
        XCTAssertTrue(dynamicRange.label.contains("200%"))
        reveal(balance, in: app)
        XCTAssertTrue(balance.label.contains("Colour temperature"))
        shot(app, "Convertible X-T5 recipe saved and reopened")
        app.buttons["recipe.editor.cancel"].tap()
        phone.tap()
        wait { app.buttons["workspace.export"].isEnabled }
    }
}
