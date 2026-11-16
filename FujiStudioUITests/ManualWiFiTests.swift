import XCTest

final class ManualWiFiTests: XCTestCase {
  func testIdentityRequiresManualWiFiConfirmation() {
    let app = XCUIApplication()
    app.launchArguments = ["--manual-wifi-fixture"]
    app.launch()

    let find = app.buttons["manualWiFi.findPaired"]
    XCTAssertTrue(find.waitForExistence(timeout: 10))
    find.tap()
    let connect = app.buttons["manualWiFi.pairedCamera"].firstMatch
    XCTAssertTrue(connect.waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["manualWiFi.status"].label.contains("Choose the paired X-T5"))
    connect.tap()

    let start = app.buttons["manualWiFi.startWiFi"]
    XCTAssertTrue(start.waitForExistence(timeout: 10))
    XCTAssertFalse(start.isEnabled)
    XCTAssertFalse(app.buttons["manualWiFi.reveal"].exists)
    app.buttons["manualWiFi.confirmRegistration"].tap()
    XCTAssertTrue(start.isEnabled)
    start.tap()

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

  func testPairingInstructionsAppearOnlyInTheNewCameraFlow() {
    let app = XCUIApplication()
    app.launchArguments = ["--manual-wifi-fixture"]
    app.launch()

    let pair = app.buttons["manualWiFi.newPairing"]
    XCTAssertTrue(pair.waitForExistence(timeout: 10))
    XCTAssertFalse(app.staticTexts["manualWiFi.status"].label.contains("open Pairing Registration"))
    pair.tap()
    XCTAssertTrue(app.buttons["Pair with New fixture X-T5"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["manualWiFi.status"].label.contains("open Pairing Registration"))
    XCTAssertFalse(app.buttons["manualWiFi.pairedCamera"].exists)
  }
}
