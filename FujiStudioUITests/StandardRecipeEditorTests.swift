import XCTest

@MainActor
final class StandardRecipeEditorTests: AppFlowTestCase {
  func testRetargetingKeepsInvalidToneSelectionAndBlocksSaveUntilFixed() {
    let app = launch()
    wait { app.buttons["app.status"].label.contains("Camera ready") }
    tap(app.buttons["recipe.control"], in: app)
    app.buttons["recipe.copy.1"].tap()
    let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.edit."))
      .firstMatch
    XCTAssertTrue(edit.waitForExistence(timeout: 5))
    edit.tap()
    let highlight = app.buttons["recipe.editor.setting.highlight"]
    reveal(highlight, in: app)
    highlight.tap()
    selectRecipeChoice("+1.5", for: highlight, in: app)
    let camera = app.buttons["recipe.editor.camera"]
    reveal(camera, in: app, towardsTop: true)
    camera.tap()
    selectRecipeChoice("X-E3", for: camera, in: app)
    XCTAssertFalse(app.buttons["recipe.editor.save"].isEnabled)
    reveal(highlight, in: app)
    XCTAssertTrue(highlight.label.contains("+1.5"))
    XCTAssertEqual(highlight.value as? String, "Unavailable")
    shot(app, "Retained unavailable tone is shown in red")
    highlight.tap()
    XCTAssertTrue(app.buttons["+1"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["+1.5"].exists)
    XCTAssertTrue(app.buttons["+1"].isEnabled)
    selectRecipeChoice("+1", for: highlight, in: app)
    XCTAssertTrue(app.buttons["recipe.editor.save"].isEnabled)
    XCTAssertNotEqual(highlight.value as? String, "Unavailable")
    let chrome = app.buttons["recipe.editor.setting.colorChrome"]
    XCTAssertFalse(chrome.exists)
    shot(app, "X-E3 editor hides unavailable fields")
    saveRecipe(in: app)
    XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout: 5))
    edit.tap()
    XCTAssertTrue(camera.label.contains("X-E3"))
    reveal(highlight, in: app)
    XCTAssertTrue(highlight.label.contains("+1"))
    app.buttons["recipe.editor.cancel"].tap()
  }

  func testMonochromeControlsHideForColourFilmAndKeepTheirValues() {
    let app = launch()
    wait { app.buttons["app.status"].label.contains("Camera ready") }
    tap(app.buttons["recipe.control"], in: app)
    app.buttons["recipe.copy.1"].tap()
    let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.edit."))
      .firstMatch
    XCTAssertTrue(edit.waitForExistence(timeout: 5))
    edit.tap()
    // Settle a delayed Name keyboard before opening the film menu.
    let name = app.textFields["recipe.editor.name"]
    let originalName = name.value as? String
    XCTAssertNotNil(originalName)
    name.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    reveal(app.buttons["recipe.editor.setting.film"], in: app)
    XCTAssertEqual(name.value as? String, originalName)
    let warm = app.buttons["recipe.editor.setting.monochromeWarmCool"]
    XCTAssertFalse(warm.exists)
    selectFilm("ACROS", in: app)
    reveal(warm, in: app)
    XCTAssertTrue(warm.isEnabled)
    warm.tap()
    selectRecipeChoice("+5", for: warm, in: app)
    selectFilm("PROVIA / Standard", in: app)
    XCTAssertTrue(warm.waitForNonExistence(timeout: 5))
    selectFilm("ACROS", in: app)
    reveal(warm, in: app)
    XCTAssertTrue(warm.isEnabled)
    XCTAssertTrue(warm.label.contains("+5"))
    shot(app, "Film-dependent monochromatic colour retains its value")
    app.buttons["recipe.editor.cancel"].tap()
  }

  private func selectFilm(_ name: String, in app: XCUIApplication) {
    let film = app.buttons["recipe.editor.setting.film"]
    reveal(film, in: app, towardsTop: true)
    film.tap()
    selectRecipeChoice(name, for: film, in: app)
  }
}
