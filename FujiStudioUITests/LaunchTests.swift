import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testLaunchDoesNotRequestCameraAccess() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["fujiStudioTitle"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }
}
