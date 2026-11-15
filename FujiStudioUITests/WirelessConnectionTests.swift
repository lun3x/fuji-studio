import XCTest

@MainActor final class WirelessConnectionTests: AppFlowTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testStatusSeparatesBluetoothFromUSBReadiness() {
        let app = launch(["--fixture-wireless-paired"])
        let status = app.buttons["app.status"]
        wait { (status.value as? String)?.contains("Bluetooth connected") == true }
        XCTAssertNotEqual(status.value as? String, "Camera ready")
        status.tap()
        XCTAssertTrue(app.buttons["wireless.connect"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["wireless.connect"].label, "Connect over WiFi")
        XCTAssertEqual(app.staticTexts["wireless.bluetooth"].label, "Bluetooth connected")
        XCTAssertTrue(app.staticTexts["app.camera"].label.contains("USB"))
        XCTAssertEqual(app.staticTexts["wireless.wifi"].label, "WiFi import disconnected")
    }

    func testPairAndForgetXT5() {
        let app = pair(model: "X-T5", fixture: "--fixture-wireless-unpaired")
        wait { app.staticTexts["wireless.selected"].label == "Fixture X-T5" }
        app.buttons["wireless.forget"].tap()
        app.alerts.buttons["Forget camera"].tap()
        XCTAssertTrue(app.buttons["wireless.pair"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["wireless.selected"].exists)
    }

    func testPairXE3() {
        let app = pair(model: "X-E3", fixture: "--fixture-wireless-xe3-unpaired")
        wait { app.staticTexts["wireless.selected"].label == "Fixture X-E3" }
        XCTAssertEqual(app.buttons["wireless.autoSave"].label, "Set up RAW transfer")
        XCTAssertTrue(app.buttons["wireless.connect"].isEnabled)
    }

    private func pair(model: String, fixture: String) -> XCUIApplication {
        let app = launch([fixture])
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.buttons["wireless.pair"].waitForExistence(timeout: 5))
        app.buttons["wireless.pair"].tap()
        let camera = cameraButton(prefix: "wireless.discovered.\(model).", in: app)
        XCTAssertTrue(camera.waitForExistence(timeout: 5))
        camera.tap()
        return app
    }

    func testChangeBetweenTwoSavedCamerasWithoutPairingAgain() {
        let app = launch(["--fixture-wireless-two-saved"])
        app.buttons["app.status"].tap()
        let change = app.buttons["wireless.change"]
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        change.tap()
        cameraButton(prefix: "wireless.saved.X-E3.", in: app).tap()
        wait { app.staticTexts["wireless.selected"].label == "Fixture X-E3" }
        XCTAssertTrue(app.buttons["wireless.autoSave"].exists)
        change.tap()
        cameraButton(prefix: "wireless.saved.X-T5.", in: app).tap()
        wait { app.staticTexts["wireless.selected"].label == "Fixture X-T5" }
        XCTAssertFalse(app.buttons["wireless.autoSave"].exists)
    }

    func testConnectWhileBluetoothReconnectsAndCancel() {
        let app = launch(["--fixture-wireless-reconnecting"])
        app.buttons["app.status"].tap()
        let connect = app.buttons["wireless.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertTrue(connect.isEnabled)
        connect.tap()
        wait { app.staticTexts["wireless.wifi"].label.contains("Waiting for Bluetooth") }
        app.buttons["wireless.cancel"].tap()
        wait { app.staticTexts["wireless.wifi"].label == "WiFi import disconnected" }
        XCTAssertFalse(app.buttons["wireless.browse"].exists)
        connect.tap()
        wait { app.staticTexts["wireless.wifi"].label.contains("Waiting for Bluetooth") }
        app.buttons["Done"].tap()
        app.buttons["app.status"].tap()
        wait { app.staticTexts["wireless.wifi"].label == "WiFi import disconnected" }
        connect.tap()
        XCTAssertTrue(app.buttons["wireless.browse"].waitForExistence(timeout: 12))
        app.buttons["Done"].tap()
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.buttons["wireless.browse"].waitForExistence(timeout: 5))
    }

    func testRetryBluetoothAuthentication() {
        let app = launch(["--fixture-wireless-retry-bluetooth"])
        app.buttons["app.status"].tap()
        let retry = app.buttons["wireless.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["wireless.bluetoothFailure"].label.contains("authentication"))
        retry.tap()
        wait { app.staticTexts["wireless.bluetooth"].label == "Bluetooth connected" }
    }

    func testDismissalCancelsPairingBeforeHeldUSBHandoffCompletes() {
        for interactive in [false, true] {
            let app = launch(["--fixture-wireless-unpaired", "--fixture-held-usb-close"])
            let status = app.buttons["app.status"]
            wait { status.value as? String == "Camera ready" }
            status.tap()
            let pair = app.buttons["wireless.pair"]
            XCTAssertTrue(pair.waitForExistence(timeout: 5))
            pair.tap()
            if interactive {
                let bar = app.navigationBars["Status & settings"]
                let top = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 450)))
            } else {
                app.buttons["Done"].tap()
            }
            let release = app.buttons["fixture.finishUSBClose"]
            XCTAssertTrue(release.waitForExistence(timeout: 5))
            XCTAssertEqual(release.value as? String, "USB close held")
            release.tap()
            wait { status.value as? String == "Camera ready" }
            status.tap()
            XCTAssertTrue(pair.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["wireless.cancel"].exists)
            app.terminate()
        }
    }

    func testFirmwareGuidanceComesFromAuthenticatedTransferFirmware() {
        for (fixture, guidance) in [
            ("--fixture-wireless-firmware-update", "Firmware update required. Update the X-T5 to firmware 4.32"),
            ("--fixture-wireless-firmware-unverified", "Firmware version 4.33 on the X-T5 is unverified")
        ] {
            let app = launch([fixture])
            app.buttons["app.status"].tap()
            app.buttons["wireless.connect"].tap()
            let message = app.staticTexts["wireless.firmware"]
            XCTAssertTrue(message.waitForExistence(timeout: 5))
            XCTAssertTrue(message.label.contains(guidance))
            XCTAssertFalse(app.buttons["wireless.browse"].exists)
            app.terminate()
        }
    }

    func testWiFiJoinDenialAndLocalNetworkDenialHaveDifferentActions() {
        for (fixture, guidance, settings) in [
            ("--fixture-wireless-join-denied", "approve Join", false),
            ("--fixture-wireless-local-network-denied", "Local Network access is required", true)
        ] {
            let app = launch([fixture])
            app.buttons["app.status"].tap()
            app.buttons["wireless.connect"].tap()
            let message = app.staticTexts["wireless.wifiFailure"]
            XCTAssertTrue(message.waitForExistence(timeout: 5))
            XCTAssertTrue(message.label.contains(guidance))
            XCTAssertEqual(app.buttons["wireless.settings"].exists, settings)
            XCTAssertFalse(app.buttons["wireless.browse"].exists)
            app.terminate()
        }
    }

    private func cameraButton(prefix: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }
}
