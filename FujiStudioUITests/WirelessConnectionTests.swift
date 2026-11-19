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
        XCTAssertEqual(app.buttons["wireless.connect"].label, "Connect for photo import")
        XCTAssertEqual(app.staticTexts["wireless.bluetooth"].label, "Bluetooth connected")
        XCTAssertTrue(app.staticTexts["app.camera"].label.contains("USB"))
        XCTAssertFalse(app.staticTexts["wireless.wifi"].exists)
    }

    func testPairAndForgetXT5() {
        let app = launch(["--fixture-wireless-unpaired"])
        app.buttons["app.status"].tap()
        XCTAssertFalse(app.buttons["wireless.pair"].exists)
        XCTAssertTrue(app.buttons["wireless.model.xe3"].exists)
        shot(app, "Camera model picker")
        app.buttons["wireless.model.xt5"].tap()
        XCTAssertTrue(app.staticTexts["wireless.pairInstructions"].label.contains("Pairing Registration"))
        app.buttons["wireless.pair"].tap()
        let xt5 = cameraButton(prefix: "wireless.discovered.X-T5.", in: app)
        XCTAssertTrue(xt5.waitForExistence(timeout: 5))
        xt5.tap()
        wait { app.staticTexts["wireless.selected"].label == "Fixture X-T5" }
        XCTAssertFalse(app.buttons["wireless.forget"].exists)
        app.buttons["wireless.change"].tap()
        app.buttons["Pair another camera"].tap()
        XCTAssertTrue(app.buttons["wireless.model.xe3"].exists)
        XCTAssertFalse(app.buttons["wireless.connect"].exists)
        app.buttons["Cancel"].tap()
        app.buttons["wireless.change"].tap()
        app.buttons["wireless.forget"].tap()
        app.alerts.buttons["Forget camera"].tap()
        XCTAssertTrue(app.buttons["wireless.model.xt5"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["wireless.selected"].exists)
    }

    func testXE3ImmediatelyExplainsUnavailablePCModeWithoutBluetoothSetup() {
        let app = launch(["--fixture-wireless-xe3-unpaired"])
        app.buttons["app.status"].tap()
        app.buttons["wireless.model.xe3"].tap()
        let reason = app.staticTexts["wireless.autoSave.unavailable"]
        XCTAssertTrue(reason.waitForExistence(timeout: 5))
        XCTAssertTrue(reason.label.contains("Multicast Networking"))
        shot(app, "X-E3 PC Auto Save unavailable")
        XCTAssertFalse(app.buttons["wireless.autoSave.register"].exists)
        XCTAssertFalse(app.staticTexts["wireless.autoSave.network"].exists)
        XCTAssertFalse(app.buttons["wireless.pair"].exists)
        let xt5 = app.buttons["wireless.model.xt5"]
        let xe3 = app.buttons["wireless.model.xe3"]
        XCTAssertTrue(app.navigationBars["Status & settings"].exists)
        XCTAssertEqual(xe3.value as? String, "Expanded")
        xt5.tap()
        XCTAssertEqual(xe3.value as? String, "Collapsed")
        XCTAssertFalse(reason.exists)
        XCTAssertTrue(app.buttons["wireless.pair"].exists)
        xt5.tap()
        XCTAssertFalse(app.buttons["wireless.pair"].exists)
        xe3.tap()
        XCTAssertTrue(reason.waitForExistence(timeout: 5))
        xe3.tap()
        XCTAssertFalse(reason.exists)
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
        wait { connect.exists && !app.staticTexts["wireless.wifi"].exists }
        XCTAssertFalse(app.buttons["wireless.browse"].exists)
        connect.tap()
        wait { app.staticTexts["wireless.wifi"].label.contains("Waiting for Bluetooth") }
        app.buttons["Done"].tap()
        app.buttons["app.status"].tap()
        wait { connect.exists && !app.staticTexts["wireless.wifi"].exists }
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
            app.buttons["wireless.model.xt5"].tap()
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
            XCTAssertTrue(app.buttons["wireless.model.xt5"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["wireless.cancel"].exists)
            app.terminate()
        }
    }

    func testFirmwareGuidanceComesFromAuthenticatedTransferFirmware() {
        for (fixture, guidance) in [
            ("--fixture-wireless-firmware-update", "Firmware update required. Update the X-T5 to firmware 4.30 or later"),
            ("--fixture-wireless-firmware-unverified", "The X-T5 firmware version could not be verified")
        ] {
            let app = launch([fixture])
            app.buttons["app.status"].tap()
            app.buttons["wireless.connect"].tap()
            let message = app.staticTexts["wireless.firmware"]
            XCTAssertTrue(message.waitForExistence(timeout: 5))
            XCTAssertTrue(message.label.contains(guidance))
            let instructions = app.descendants(matching: .any)["wireless.firmwareInstructions"].firstMatch
            XCTAssertEqual(instructions.exists, fixture == "--fixture-wireless-firmware-update")
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
