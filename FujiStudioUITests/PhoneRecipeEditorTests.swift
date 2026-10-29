import XCTest

@MainActor
final class PhoneRecipeEditorTests: AppFlowTestCase {
    func testPhoneEditorGrainEffectAndSizeSaveIndependently() {
        let app = launch(["--fixture-disconnected-camera"])
        tap(app.buttons["recipe.control"], in: app); app.buttons["recipe.copy.3"].tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.edit.")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        let effect = app.buttons["recipe.editor.setting.grainEffect"]
        let size = app.buttons["recipe.editor.setting.grainSize"]
        XCTAssertTrue(effect.waitForExistence(timeout: 5))
        reveal(effect, in: app); effect.tap(); app.buttons["Weak"].tap()
        XCTAssertTrue(size.isEnabled)
        size.tap(); app.buttons["Large"].tap()
        effect.tap(); app.buttons["Off"].tap()
        XCTAssertFalse(size.isEnabled); XCTAssertTrue(size.label.contains("Large"))
        shot(app, "Grain Off disables size and retains Large")
        effect.tap(); app.buttons["Strong"].tap()
        XCTAssertTrue(size.isEnabled); XCTAssertTrue(size.label.contains("Large"))
        app.buttons["recipe.editor.save"].tap()
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout: 5))
        edit.tap(); reveal(effect, in: app)
        XCTAssertTrue(effect.label.contains("Strong")); XCTAssertTrue(size.label.contains("Large"))
        effect.tap(); app.buttons["Off"].tap(); app.buttons["recipe.editor.save"].tap()
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout: 5))
        edit.tap(); reveal(effect, in: app)
        XCTAssertTrue(effect.label.contains("Off")); XCTAssertFalse(size.isEnabled)
        XCTAssertTrue(size.label.contains("Small"))
        effect.tap(); app.buttons["Weak"].tap()
        XCTAssertTrue(size.isEnabled); XCTAssertTrue(size.label.contains("Small"))
        size.tap(); app.buttons["Small"].tap()
        XCTAssertTrue(effect.label.contains("Weak")); XCTAssertTrue(size.label.contains("Small"))
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
        app.buttons["recipe.editor.setting.film"].tap()
        app.buttons["PROVIA / Standard"].tap()
        replaceText(app.textFields["recipe.editor.name"], with: "My Provia")
        shot(app, "Phone editor name and film draft")
        app.buttons["recipe.editor.save"].tap()
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons[id].label.contains("My Provia"))
        XCTAssertFalse(app.buttons[id].isEnabled)
        edit.tap()
        XCTAssertEqual(app.textFields["recipe.editor.name"].value as? String, "My Provia")
        let film = app.buttons["recipe.editor.setting.film"]
        XCTAssertTrue(film.label.contains("PROVIA") || (film.value as? String ?? "").contains("PROVIA"))
        replaceText(app.textFields["recipe.editor.name"], with: "Discard me")
        app.buttons["recipe.editor.cancel"].tap()
        XCTAssertTrue(app.buttons[id].label.contains("My Provia"))
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
        app.buttons["+3.5"].tap()
        app.buttons["recipe.editor.save"].tap()
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
        reveal(balance, in: app); balance.tap(); app.buttons["Colour temperature"].tap()
        let temperature = app.textFields["recipe.editor.temperature"]
        reveal(temperature, in: app); replaceText(temperature, with: "10001")
        shot(app, "Phone editor temperature draft before validation")
        app.buttons["recipe.editor.save"].tap()
        XCTAssertTrue(app.staticTexts["recipe.editor.error"].waitForExistence(timeout: 5))
        XCTAssertEqual(temperature.value as? String, "10001")
        replaceText(temperature, with: "5200")
        app.buttons["recipe.editor.save"].tap()
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
        reveal(effect, in: app); effect.tap(); app.buttons["Off"].tap()
        let size = app.buttons["recipe.editor.setting.grainSize"]
        reveal(size, in: app); XCTAssertFalse(size.isEnabled)
        shot(app, "Phone editor at largest text")
        XCTAssertTrue(app.buttons["recipe.editor.save"].isHittable)
        XCTAssertTrue(app.buttons["recipe.editor.cancel"].isHittable)
        app.buttons["recipe.editor.cancel"].tap()
    }
}
