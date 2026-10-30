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
    app.buttons["+1.5"].tap()
    let camera = app.buttons["recipe.editor.camera"]
    reveal(camera, in: app, towardsTop: true)
    camera.tap()
    app.buttons["X-E3"].tap()
    XCTAssertFalse(app.buttons["recipe.editor.save"].isEnabled)
    reveal(highlight, in: app)
    XCTAssertTrue(highlight.label.contains("+1.5"))
    highlight.tap()
    XCTAssertFalse(app.buttons["+1.5"].isEnabled)
    XCTAssertTrue(app.buttons["+1"].isEnabled)
    app.buttons["+1"].tap()
    XCTAssertTrue(app.buttons["recipe.editor.save"].isEnabled)
    let chrome = app.buttons["recipe.editor.setting.colorChrome"]
    reveal(chrome, in: app)
    XCTAssertFalse(chrome.isEnabled)
    shot(app, "X-E3 standard recipe retains unavailable fields")
    app.buttons["recipe.editor.save"].tap()
    XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout: 5))
    edit.tap()
    XCTAssertTrue(camera.label.contains("X-E3"))
    reveal(highlight, in: app)
    XCTAssertTrue(highlight.label.contains("+1"))
    app.buttons["recipe.editor.cancel"].tap()
  }

  func testMonochromeControlsDisableForColourFilmAndKeepTheirValues() {
    let app = launch()
    wait { app.buttons["app.status"].label.contains("Camera ready") }
    tap(app.buttons["recipe.control"], in: app)
    app.buttons["recipe.copy.1"].tap()
    let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.edit."))
      .firstMatch
    XCTAssertTrue(edit.waitForExistence(timeout: 5))
    edit.tap()
    let warm = app.buttons["recipe.editor.setting.monochromeWarmCool"]
    reveal(warm, in: app)
    XCTAssertFalse(warm.isEnabled)
    selectFilm("ACROS", in: app)
    reveal(warm, in: app)
    XCTAssertTrue(warm.isEnabled)
    warm.tap()
    app.buttons["+5"].tap()
    selectFilm("PROVIA / Standard", in: app)
    reveal(warm, in: app)
    XCTAssertFalse(warm.isEnabled)
    XCTAssertTrue(warm.label.contains("+5"))
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
    let option = app.buttons[name]
    let menu = app.collectionViews.containing(.button, identifier: "Classic Chrome").firstMatch
    for _ in 0..<5 {
      if option.isHittable { break }
      menu.swipeDown()
    }
    XCTAssertTrue(option.isHittable)
    option.tap()
  }
}
