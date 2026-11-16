import XCTest

final class ManualWiFiTests: XCTestCase {
  func testIdentityRequiresManualWiFiConfirmation() {
    checkConnection(withoutDeviceInfo: false, expected: "X-T5 identified. Firmware 04.31.")
  }

  func testRespondingSessionShowsBluetoothProvenance() {
    checkConnection(withoutDeviceInfo: true,
      expected: "Wi-Fi session responds. Bluetooth reports X-T5 firmware 04.31. Wi-Fi identity is unavailable.")
  }

  func testGalleryRequiresManualConfirmationAndShowsSampleAfterClosure() {
    let app = XCUIApplication()
    app.launchArguments = ["--manual-wifi-fixture"]
    app.launchEnvironment["FUJI_FIXTURE_EMPTY_DEVICE_INFO"] = "1"
    app.launch()
    let find = app.buttons["manualWiFi.findPaired"]
    XCTAssertTrue(find.waitForExistence(timeout: 10))
    find.tap()
    let camera = app.buttons["manualWiFi.pairedCamera"].firstMatch
    XCTAssertTrue(camera.waitForExistence(timeout: 10))
    camera.tap()
    let start = app.buttons["manualWiFi.startWiFi"]
    XCTAssertTrue(start.waitForExistence(timeout: 10))
    app.buttons["manualWiFi.confirmRegistration"].tap()
    start.tap()

    let confirm = app.buttons["manualWiFi.confirm"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 10))
    let list = app.buttons["manualWiFi.listPhotos"]
    for _ in 0..<3 where !list.isHittable { app.swipeUp() }
    XCTAssertTrue(list.exists)
    XCTAssertFalse(list.isEnabled)
    if !confirm.isHittable { app.swipeDown() }
    confirm.tap()
    for _ in 0..<3 where !list.isHittable { app.swipeUp() }
    XCTAssertTrue(list.isEnabled)
    list.tap()

    let status = app.staticTexts["manualWiFi.status"]
    let completed = NSPredicate(format: "label CONTAINS %@", "Connection closed after the test.")
    let finished = XCTNSPredicateExpectation(predicate: completed, object: status)
    XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 10), .completed)
    XCTAssertTrue(status.label.contains("Wi-Fi identity is unavailable"))
    XCTAssertTrue(app.staticTexts["2 camera objects. Sampled 2: 1 JPEG, 1 RAF, 0 other."].exists)
    XCTAssertTrue(app.staticTexts["FIXTURE.JPG"].exists)
    XCTAssertTrue(app.staticTexts["Unavailable"].exists)
  }

  private func checkConnection(withoutDeviceInfo: Bool, expected: String) {
    let app = XCUIApplication()
    app.launchArguments = ["--manual-wifi-fixture"]
    if withoutDeviceInfo { app.launchEnvironment["FUJI_FIXTURE_EMPTY_DEVICE_INFO"] = "1" }
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
    let password = app.buttons["manualWiFi.password"]
    XCTAssertFalse(password.exists)
    reveal.tap()
    XCTAssertTrue(password.exists)
    XCTAssertEqual(password.value as? String, "fixture-password")
    XCTAssertFalse(app.staticTexts["manualWiFi.passwordCopied"].exists)
    password.tap()
    XCTAssertTrue(app.staticTexts["manualWiFi.passwordCopied"].exists)

    let identify = app.buttons["manualWiFi.identify"]
    let confirm = app.buttons["manualWiFi.confirm"]
    for _ in 0..<3 where !identify.isHittable { app.swipeUp() }
    XCTAssertTrue(identify.exists)
    XCTAssertFalse(identify.isEnabled)
    confirm.tap()
    XCTAssertTrue(identify.isEnabled)
    identify.tap()

    let status = app.staticTexts.matching(NSPredicate(format: "label == %@", expected)).firstMatch
    XCTAssertTrue(status.waitForExistence(timeout: 10))
    XCTAssertFalse(password.exists)
    XCTAssertFalse(app.staticTexts["manualWiFi.passwordCopied"].exists)
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
