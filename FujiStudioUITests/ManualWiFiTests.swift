import XCTest

final class ManualWiFiTests: XCTestCase {
  func testIdentityRequiresManualWiFiConfirmation() {
    let app = XCUIApplication()
    app.launchArguments = ["--manual-wifi-fixture"]
    app.launch()

    let connect = app.buttons["manualWiFi.savedCamera"].firstMatch
    XCTAssertTrue(connect.waitForExistence(timeout: 10))
    connect.tap()

    let reveal = app.buttons["manualWiFi.reveal"]
    XCTAssertTrue(reveal.waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["manualWiFi.password"].exists)
    reveal.tap()
    XCTAssertTrue(app.staticTexts["manualWiFi.password"].exists)

    let identify = app.buttons["manualWiFi.identify"]
    let confirm = app.buttons["manualWiFi.confirm"]
    for _ in 0..<3 where !identify.isHittable { app.swipeUp() }
    XCTAssertTrue(identify.exists)
    XCTAssertFalse(identify.isEnabled)
    confirm.tap()
    XCTAssertTrue(identify.isEnabled)
    identify.tap()

    let status = app.staticTexts.matching(NSPredicate(format: "label == %@", "X-T5 identified. Firmware 04.31.")).firstMatch
    XCTAssertTrue(status.waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["manualWiFi.password"].exists)
  }
}
