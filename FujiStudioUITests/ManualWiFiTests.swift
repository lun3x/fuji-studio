import XCTest

final class ManualWiFiTests: XCTestCase {
  func testIdentityRequiresManualWiFiConfirmation() {
    checkConnection(withoutDeviceInfo: false, expected: "X-T5 identified. Firmware 04.31.")
  }

  func testRespondingSessionShowsBluetoothProvenance() {
    checkConnection(withoutDeviceInfo: true,
      expected: "Wi-Fi session responds. Bluetooth reports X-T5 firmware 04.31. Wi-Fi identity is unavailable.")
  }

  func testGalleryRequiresManualConfirmationAndShowsCompleteCountsAfterClosure() {
    checkGallery(.scan)
  }

  func testPairTestRequiresManualConfirmationAndShowsNoPairAfterFullScan() {
    checkGallery(.pair)
  }

  func testPhotoCountsRequireManualConfirmationAndShowCardAvailability() {
    checkGallery(.count)
  }

  private enum GalleryAction: String {
    case count = "countPhotos", scan = "listPhotos", pair = "testPair"
  }

  private func checkGallery(_ action: GalleryAction) {
    let app = XCUIApplication()
    app.launchArguments = ["--manual-wifi-fixture"]
    app.launchEnvironment["FUJI_FIXTURE_EMPTY_DEVICE_INFO"] = "1"
    if action == .pair { app.launchEnvironment["FUJI_FIXTURE_JPEG_ONLY"] = "1" }
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
    let list = app.buttons["manualWiFi.\(action.rawValue)"]
    for _ in 0..<3 where !list.isHittable { app.swipeUp() }
    guard list.exists else {
      XCTFail("The gallery action is missing")
      return
    }
    XCTAssertFalse(list.isEnabled)
    if !confirm.isHittable || confirm.frame.midY < app.frame.height * 0.25 {
      app.swipeDown()
    }
    confirm.tap()
    XCTAssertFalse(confirm.isEnabled)
    for _ in 0..<3 where !list.isHittable { app.swipeUp() }
    guard list.isEnabled else {
      XCTFail("The gallery action remained disabled after confirmation")
      return
    }
    list.tap()

    let status = app.staticTexts["manualWiFi.status"]
    let completed = NSPredicate(format: "label CONTAINS %@", "Connection closed after the test.")
    let finished = XCTNSPredicateExpectation(predicate: completed, object: status)
    XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 10), .completed)
    if action == .count {
      let first = app.descendants(matching: .any)["manualWiFi.photoCount.1"]
      let second = app.descendants(matching: .any)["manualWiFi.photoCount.2"]
      XCTAssertEqual(first.value as? String, "2 items")
      XCTAssertEqual(second.value as? String, "Unavailable")
      XCTAssertFalse(app.staticTexts["FIXTURE.JPG"].exists)
      XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Scanned ")).firstMatch.exists)
      return
    }
    XCTAssertTrue(status.label.contains("Wi-Fi identity is unavailable"))
    if action == .pair {
      XCTAssertTrue(status.label.contains("No unambiguous JPEG+RAW pair"))
      XCTAssertTrue(app.staticTexts["Scanned 40 of 40 objects: 40 JPEG, 0 RAF, 0 other."].exists)
    } else {
      XCTAssertTrue(app.staticTexts["Scanned 2 of 2 objects: 1 JPEG, 1 RAF, 0 other."].exists)
      XCTAssertTrue(app.staticTexts["FIXTURE.JPG"].exists)
      XCTAssertTrue(app.staticTexts["Unavailable"].exists)
    }
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
