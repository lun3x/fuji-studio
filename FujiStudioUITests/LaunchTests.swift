import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testLaunchDoesNotRequestCameraAccess() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixtures"]
        app.launch()
        XCTAssertTrue(app.buttons["workspace.select"].waitUntilExists(timeout: 10))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }
}
