import UIKit
import XCTest

@MainActor final class CameraImportTests: AppFlowTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func browse(_ app: XCUIApplication) {
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.buttons["wireless.connect"].waitForExistence(timeout: 5))
        app.buttons["wireless.connect"].tap()
        browseConnectedCamera(app)
    }

    private func browseConnectedCamera(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["wireless.browse"].waitForExistence(timeout: 8))
        if !app.buttons["wireless.browse"].isHittable { reveal(app.buttons["wireless.browse"], in: app) }
        app.buttons["wireless.browse"].tap()
        XCTAssertTrue(app.navigationBars["Camera photos"].waitForExistence(timeout: 5))
    }

    func testPairIsOnePhotoAndViewImportedReturnsToLibrary() {
        let app = launch(["--fixture-wireless-paired"])
        browse(app)
        let pair = app.buttons["cameraBrowser.select.1.1"]
        let raw = app.buttons["cameraBrowser.rawOnly.1.3"]
        wait { pair.isEnabled && raw.isEnabled }
        XCTAssertTrue(pair.label.contains("RAW+JPEG"))
        XCTAssertTrue(raw.label.contains("RAW"))
        pair.tap()
        XCTAssertEqual(app.staticTexts["cameraBrowser.selection"].label, "1 photo selected")
        XCTAssertTrue(app.staticTexts["cameraBrowser.bytes"].label.contains("Estimated"))
        let submit = app.buttons["cameraBrowser.import"]
        XCTAssertEqual(submit.label, "Import 1 photo")
        submit.tap()
        let view = app.buttons["cameraImport.viewImported"]
        XCTAssertTrue(view.waitForExistence(timeout: 10))
        app.buttons["cameraImport.done"].tap()
        wait { app.staticTexts["cameraBrowser.selection"].label == "0 photos selected" }
        XCTAssertFalse(submit.isEnabled)
        XCTAssertEqual(pair.value as? String, "Imported")
        app.buttons["cameraBrowser.done"].tap()
        app.buttons["cameraImport.open"].tap()
        view.tap()
        XCTAssertTrue(app.cells["grid.wireless-1"].waitForExistence(timeout: 8))
    }

    func testUnverifiedSaveRetainsOriginalsOutsideTray() {
        let app = launch(["--fixture-wireless-unverified-save"])
        browse(app)
        let pair = app.buttons["cameraBrowser.select.1.1"]
        wait { pair.isEnabled }
        pair.tap()
        app.buttons["cameraBrowser.import"].tap()
        wait { app.staticTexts["cameraImport.status"].label.contains("unverified") }
        XCTAssertTrue(app.staticTexts["cameraImport.retainedBytes"].exists)
        XCTAssertTrue(app.buttons["cameraImport.managePhotos"].exists)
        XCTAssertTrue(app.staticTexts["cameraImport.guidance"].label.contains("check the same save"))
        XCTAssertFalse(app.buttons["cameraImport.viewImported"].exists)
        XCTAssertFalse(app.buttons["cameraImport.discard"].exists)
        app.buttons["cameraImport.done"].tap()
        XCTAssertTrue(app.buttons["cameraBrowser.done"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["cameraBrowser.selection"].label, "1 photo selected")
        app.buttons["cameraBrowser.done"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertFalse(app.cells["grid.wireless-1"].exists)
    }

    func testProgressiveFormatsAndExplicitRAWOnlySelection() {
        let app = launch(["--fixture-wireless-formats"])
        browse(app)
        let checking = app.descendants(matching: .any)["cameraBrowser.format.1.1"].firstMatch
        XCTAssertTrue(checking.waitForExistence(timeout: 3))
        XCTAssertTrue(checking.label.contains("Checking files"))
        XCTAssertFalse(app.buttons["cameraBrowser.import"].isEnabled)
        let pair = app.buttons["cameraBrowser.select.1.1"]
        wait { pair.exists && pair.isEnabled }
        let rawOnly = app.buttons["cameraBrowser.rawOnly.1.3"]
        XCTAssertEqual(rawOnly.label, "Import RAW only")
        XCTAssertFalse(app.buttons["cameraBrowser.rawOnly.1.1"].exists)
        pair.tap()
        let pairEstimate = app.staticTexts["cameraBrowser.bytes"].label
        pair.tap()
        rawOnly.tap()
        XCTAssertEqual(rawOnly.value as? String, "Selected")
        XCTAssertEqual(app.staticTexts["cameraBrowser.selection"].label, "1 photo selected")
        XCTAssertNotEqual(app.staticTexts["cameraBrowser.bytes"].label, pairEstimate)
        let jpeg = app.descendants(matching: .any)["cameraBrowser.format.1.4"].firstMatch
        if !jpeg.isHittable { reveal(jpeg, in: app) }
        XCTAssertTrue(jpeg.label.contains("JPEG only"))
        XCTAssertFalse(app.buttons["cameraBrowser.select.1.4"].exists)
        let ambiguousMate = app.buttons["cameraBrowser.rawOnly.1.5"]
        if !ambiguousMate.isHittable { reveal(ambiguousMate, in: app) }
        XCTAssertTrue(ambiguousMate.isEnabled)
        let duplicateRAW = app.buttons["cameraBrowser.rawOnly.1.7"]
        if !duplicateRAW.isHittable { reveal(duplicateRAW, in: app) }
        XCTAssertFalse(duplicateRAW.isEnabled)
        app.buttons["cameraBrowser.import"].tap()
        wait { app.staticTexts["cameraImport.status"].label == "Import complete" }
        app.buttons["cameraImport.done"].tap()
        wait { app.staticTexts["cameraBrowser.selection"].label == "0 photos selected" }
        XCTAssertFalse(app.buttons["cameraBrowser.import"].isEnabled)
        let raw = app.descendants(matching: .any)["cameraBrowser.format.1.3"].firstMatch
        let browser = app.scrollViews["cameraBrowser.scroll"]
        for _ in 0..<5 where !raw.isHittable { browser.swipeDown() }
        XCTAssertTrue(raw.label.contains("DSCF0002.RAF, RAW, Imported"))
    }

    func testActiveSelectionIsFrozenAndCancelStaysReachable() {
        let app = launch(["--fixture-wireless-slow-import"])
        browse(app)
        let pair = app.buttons["cameraBrowser.select.1.1"]
        wait { pair.isEnabled }
        pair.tap()
        app.buttons["cameraBrowser.import"].tap()
        wait { app.staticTexts["cameraImport.status"].label == "Downloading photo 1 of 1" }
        XCTAssertTrue(app.progressIndicators["cameraImport.progress"].exists)
        app.buttons["cameraImport.done"].tap()
        XCTAssertFalse(pair.isEnabled)
        XCTAssertFalse(app.buttons["cameraBrowser.rawOnly.1.3"].isEnabled)
        XCTAssertEqual(app.staticTexts["cameraBrowser.selection"].label, "1 photo selected")
        app.buttons["cameraBrowser.done"].tap()
        app.buttons["cameraImport.open"].tap()
        XCTAssertTrue(app.buttons["cameraImport.cancel"].isHittable)
        app.buttons["cameraImport.cancel"].tap()
        wait { app.staticTexts["cameraImport.status"].label == "Import cancelled" }
    }

    func testConnectionLossCanResumeWithRetainedBytes() {
        let app = launch(["--fixture-wireless-recoverable"])
        browse(app)
        importPair(app)
        let resume = app.buttons["cameraImport.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        XCTAssertFalse(resume.isEnabled)
        XCTAssertTrue(app.staticTexts["cameraImport.retainedBytes"].exists)
        app.buttons["cameraImport.done"].tap()
        app.buttons["cameraBrowser.done"].tap()
        app.buttons["wireless.connect"].tap()
        XCTAssertTrue(app.buttons["wireless.browse"].waitForExistence(timeout: 8))
        app.buttons["cameraImport.open"].tap()
        wait { resume.isEnabled }
        resume.tap()
        wait { app.staticTexts["cameraImport.status"].label == "Import complete" }
    }

    func testDiscardRemainingReleasesRetainedFiles() {
        let app = launch(["--fixture-wireless-recoverable"])
        browse(app)
        importPair(app)
        let discard = app.buttons["cameraImport.discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 10))
        reveal(discard, in: app)
        discard.tap()
        app.alerts.buttons["Discard remaining"].tap()
        wait { !app.staticTexts["cameraImport.retainedBytes"].exists }
        XCTAssertFalse(app.buttons["cameraImport.resume"].exists)
    }

    func testRetryAndSkipRemainExplicitAfterASaveRejection() {
        for action in ["retry", "skip"] {
            let app = launch(["--fixture-wireless-retryable"])
            browse(app)
            importPair(app, includeStandalone: true)
            let button = app.buttons["cameraImport.\(action)"]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["cameraImport.retainedBytes"].exists)
            XCTAssertTrue(button.isEnabled)
            reveal(button, in: app)
            button.tap()
            let importedCount = action == "retry" ? "2" : "1"
            wait { app.staticTexts["cameraImport.counts"].label == "\(importedCount) of 2 photos imported" }
            app.terminate()
        }
    }

    func testXE3UnavailablePCTransferDoesNotOfferRegistrationOrStart() {
        let app = launch(["--fixture-wireless-raw-unavailable"])
        browse(app)
        XCTAssertTrue(app.staticTexts["cameraBrowser.rawUnavailable"].waitForExistence(timeout: 5))
        let rawUnavailable = app.descendants(matching: .any)["cameraBrowser.format.1.2"].firstMatch
        XCTAssertTrue(rawUnavailable.label.contains("RAW unavailable"))
        XCTAssertFalse(app.buttons["cameraBrowser.import"].isEnabled)
        XCTAssertFalse(app.buttons["cameraBrowser.select.1.2"].exists)
        app.buttons["cameraBrowser.autoSave"].tap()
        let unavailable = app.staticTexts["wireless.autoSave.unavailable"]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 5))
        XCTAssertTrue(unavailable.label.contains("Multicast Networking"))
        XCTAssertFalse(app.buttons["wireless.autoSave.register"].exists)
        XCTAssertFalse(app.buttons["wireless.autoSave.wait"].exists)
        XCTAssertFalse(app.buttons["wireless.browse"].exists)
    }

    func testXE3GuidesSameNetworkRegistrationAndCameraStartedTransfer() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixtures", "--fixture-wireless-auto-save"]
        app.launchEnvironment["FUJI_STUDIO_SETTINGS_SUITE"] = "FujiAutoSaveUI-\(UUID())"
        app.launch()
        openAutoSave(in: app)
        XCTAssertTrue(app.staticTexts["wireless.autoSave.network"].label.contains("same WiFi network"))
        let register = app.buttons["wireless.autoSave.register"]
        XCTAssertTrue(register.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["wireless.autoSave.setupInstructions"].label.contains("PC AUTO SAVE SETTING"))
        let waitForCamera = app.buttons["wireless.autoSave.wait"]
        XCTAssertTrue(waitForCamera.isEnabled)
        waitForCamera.tap()
        wait { app.staticTexts["wireless.autoSave.failure"].label.contains("Register a PC Auto Save destination") }
        XCTAssertFalse(waitForCamera.exists)
        register.tap()
        XCTAssertTrue(app.staticTexts["wireless.autoSave.registered"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        openAutoSave(in: app)
        XCTAssertTrue(waitForCamera.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["wireless.autoSave.registered"].exists)
        XCTAssertTrue(app.staticTexts["wireless.autoSave.startInstructions"].label.contains("playback menu"))
        waitForCamera.tap()
        browseConnectedCamera(app)
        importPair(app)
        wait { app.staticTexts["cameraImport.status"].label == "Import complete" }
    }

    private func openAutoSave(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["app.status"].waitForExistence(timeout: 10))
        app.buttons["app.status"].tap()
        let autoSave = app.buttons["wireless.autoSave"]
        XCTAssertTrue(autoSave.waitForExistence(timeout: 5))
        autoSave.tap()
    }

    func testJournalFailureWithoutAJobRemainsVisibleAndPreventsNewImports() {
        let app = launch(["--fixture-wireless-journal-issue"])
        browse(app)
        let pair = app.buttons["cameraBrowser.select.1.1"]
        wait { pair.isEnabled }
        pair.tap()
        XCTAssertFalse(app.buttons["cameraBrowser.import"].isEnabled)
        app.buttons["cameraBrowser.done"].tap()
        let issue = app.descendants(matching: .any)["cameraImport.journalIssue"].firstMatch
        XCTAssertTrue(issue.waitForExistence(timeout: 5))
        XCTAssertTrue(issue.label.contains("Camera import recovery required"))
        XCTAssertTrue(issue.label.contains("Check available iPhone storage"))
    }

    private func importPair(_ app: XCUIApplication, includeStandalone: Bool = false) {
        let pair = app.buttons["cameraBrowser.select.1.1"]
        wait { pair.isEnabled }
        pair.tap()
        if includeStandalone { app.buttons["cameraBrowser.rawOnly.1.3"].tap() }
        app.buttons["cameraBrowser.import"].tap()
    }
}
