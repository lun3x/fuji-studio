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

    func testManualNetworkSheetCanBeDismissedAndReturnsDirectlyToCameraTray() {
        let app = launch(["--fixture-wireless-manual-network"])
        let cameraPhotos = app.buttons["workspace.cameraPhotos"]
        XCTAssertTrue(cameraPhotos.waitForExistence(timeout: 8))
        cameraPhotos.tap()
        let prompt = app.navigationBars["Join camera Wi-Fi"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        let name = app.descendants(matching: .any)["cameraNetwork.ssid"].firstMatch
        XCTAssertEqual(name.value as? String, "Fixture WiFi")
        let copy = app.buttons["cameraNetwork.copy"]
        XCTAssertEqual(copy.value as? String, "camera-fixture")
        copy.tap()
        XCTAssertTrue(copy.label.contains("Password copied"))
        app.buttons["Dismiss"].tap()
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))
        cameraPhotos.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        let instructions = app.staticTexts["cameraNetwork.instructions"]
        XCTAssertTrue(instructions.label.contains("tap Back at the top left"))
        XCTAssertTrue(instructions.label.contains("Tap Wi-Fi"))
        app.buttons["Open Settings"].tap()
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 8))
        app.activate()
        XCTAssertTrue(app.buttons["cameraTray.save"].waitForExistence(timeout: 10))
        XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))
    }

    func testCameraViewerShowsPercentageDuringOriginalDownload() {
        let app = launch(["--fixture-wireless-slow-import"])
        let photos = app.buttons["workspace.cameraPhotos"]
        XCTAssertTrue(photos.waitForExistence(timeout: 8))
        photos.tap()
        let pair = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "DSCF0001.RAF")).firstMatch
        XCTAssertTrue(pair.waitForExistence(timeout: 10))
        pair.tap()
        let progress = app.descendants(matching: .any)["viewer.loading"].firstMatch
        XCTAssertTrue(progress.wait(for: \.label, toEqual: "Downloading original", timeout: 8))
        XCTAssertEqual(progress.value as? String, "50%")
        XCTAssertFalse(app.staticTexts["50%"].exists)
        XCTAssertTrue(progress.waitForNonExistence(timeout: 25))
    }

    func testCameraPhotosOpensWorkspaceVersionsAndSavesSelectedPair() {
        let app = launch(["--fixture-wireless-recovery-jobs"])
        let cameraPhotos = app.buttons["workspace.cameraPhotos"]
        XCTAssertTrue(cameraPhotos.waitForExistence(timeout: 8))
        let recipeSize = app.buttons["recipe.control"].frame.size
        wait { cameraPhotos.isEnabled && cameraPhotos.isHittable }
        cameraPhotos.tap()
        let pair = app.cells.matching(NSPredicate(format: "label CONTAINS %@", "DSCF0001.RAF")).firstMatch
        XCTAssertTrue(pair.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(pair.label.contains("RAW + JPEG"))
        let versions = app.buttons["workspace.versions"]
        XCTAssertTrue(versions.exists)
        XCTAssertFalse(versions.isEnabled)
        let saveFrame = app.buttons["cameraTray.save"].frame
        pair.tap()
        XCTAssertTrue(versions.isEnabled)
        XCTAssertTrue(versions.waitForExistence(timeout: 5))
        XCTAssertEqual(versions.value as? String, "Original camera JPEG")
        versions.tap()
        XCTAssertTrue(app.buttons["version.raw"].exists)
        app.buttons["version.cameraJPEG"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout: 10))
        let save = app.buttons["cameraTray.save"]
        XCTAssertTrue(save.isEnabled)
        XCTAssertEqual(save.frame.width, recipeSize.width, accuracy: 1)
        XCTAssertEqual(save.frame.height, recipeSize.height, accuracy: 1)
        XCTAssertEqual(save.frame.minX, saveFrame.minX, accuracy: 1)
        XCTAssertEqual(save.label, "Save to Phone")
        save.tap()
        let view = app.buttons["cameraImport.viewImported"]
        XCTAssertTrue(view.waitForExistence(timeout: 10))
        let statuses = app.staticTexts.matching(identifier: "cameraImport.status")
        XCTAssertEqual(statuses.count, 1)
        XCTAssertTrue(statuses.firstMatch.wait(for: \.label, toEqual: "Import complete", timeout: 5))
        view.tap()
        XCTAssertTrue(app.cells["grid.wireless-1"].waitForExistence(timeout: 8))
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

    func testBrowserGroupsReusedFilenamesByCameraCalendarDate() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(["--fixture-wireless-dated"])
        wait { app.windows.firstMatch.frame.height > app.windows.firstMatch.frame.width }
        browse(app)
        let newest = app.staticTexts["cameraBrowser.day.2020-01-02"]
        let older = app.staticTexts["cameraBrowser.day.2020-01-01"]
        let unknown = app.staticTexts["cameraBrowser.day.unknown"]
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        XCTAssertTrue(older.exists)
        XCTAssertLessThan(newest.frame.minY, older.frame.minY)
        let first = app.descendants(matching: .any)["cameraBrowser.format.1.1"].firstMatch
        let second = app.descendants(matching: .any)["cameraBrowser.format.1.3"].firstMatch
        XCTAssertTrue(first.label.contains("DSCF0012.RAF"))
        XCTAssertTrue(first.label.contains("2020-01-02"))
        XCTAssertTrue(second.label.contains("DSCF0012.RAF"))
        XCTAssertTrue(second.label.contains("2020-01-01"))
        shot(app, "Wireless camera calendar groups")
        let scroll = app.scrollViews["cameraBrowser.scroll"]
        scroll.swipeUp()
        XCTAssertEqual(unknown.label, "Capture date unknown")
        let invalid = app.descendants(matching: .any)["cameraBrowser.format.1.5"].firstMatch
        let missing = app.descendants(matching: .any)["cameraBrowser.format.1.7"].firstMatch
        XCTAssertTrue(invalid.isHittable)
        XCTAssertTrue(invalid.label.contains("Capture date unknown"))
        XCTAssertTrue(missing.isHittable)
        XCTAssertTrue(missing.label.contains("Capture date unknown"))
        shot(app, "Wireless camera unknown date group")
    }

    func testCompactStatusAnnouncesHeldDownloadAndReturnsToConnectionSummary() {
        let app = launch(["--fixture-wireless-slow-import"])
        browse(app)
        let pair = app.buttons["cameraBrowser.select.1.1"]
        wait { pair.isEnabled }
        pair.tap()
        app.buttons["cameraBrowser.import"].tap()
        wait { app.staticTexts["cameraImport.status"].label == "Downloading photo 1 of 1" }
        app.buttons["cameraImport.done"].tap()
        app.buttons["cameraBrowser.done"].tap()
        app.buttons["Done"].tap()
        let status = app.buttons["app.status"]
        XCTAssertTrue(status.label.contains("Downloading photo 1 of 1"))
        XCTAssertTrue((status.value as? String)?.contains("0 of 1 photo imported") == true)
        shot(app, "Wireless active download status")
        status.tap()
        app.buttons["cameraImport.open"].tap()
        app.buttons["cameraImport.pause"].tap()
        wait { app.staticTexts["cameraImport.status"].label == "Import paused" }
        app.buttons["cameraImport.done"].tap()
        app.buttons["Done"].tap()
        wait { status.label == "Bluetooth connected" }
        XCTAssertFalse((status.value as? String)?.contains("photo imported") == true)
    }

    func testCompactStatusAnnouncesLocalPhotosRetryAndPreventsCameraChanges() {
        let app = launch(["--fixture-wireless-held-local-retry"])
        browse(app)
        importPair(app)
        let retry = app.buttons["cameraImport.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        app.buttons["cameraImport.done"].tap()
        app.buttons["cameraBrowser.done"].tap()
        app.buttons["wireless.disconnect"].tap()
        let connect = app.buttons["wireless.connect"]
        wait { connect.isEnabled }
        app.buttons["cameraImport.open"].tap()
        wait { retry.isEnabled }
        retry.tap()
        wait { app.staticTexts["cameraImport.status"].label == "Saving photo 1 of 1 to Photos" }
        app.buttons["cameraImport.done"].tap()
        app.buttons["Done"].tap()
        let status = app.buttons["app.status"]
        XCTAssertTrue(status.label.contains("Saving photo 1 of 1 to Photos"))
        XCTAssertTrue((status.value as? String)?.contains("0 of 1 photo imported") == true)
        status.tap()
        let change = app.buttons["wireless.change"]
        let forget = app.buttons["wireless.forget"]
        XCTAssertTrue(change.exists)
        XCTAssertTrue(forget.exists)
        XCTAssertFalse(change.isEnabled)
        XCTAssertFalse(forget.isEnabled)
        shot(app, "Wireless camera choices disabled during local Photos save")
        app.buttons["Done"].tap()
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            status.label != "Saving photo 1 of 1 to Photos" && status.label.hasPrefix("Bluetooth")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 30), .completed)
        app.buttons["app.status"].tap()
        XCTAssertTrue(change.isEnabled)
        XCTAssertTrue(forget.isEnabled)
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
        XCTAssertFalse(app.buttons["cameraImport.managePhotos"].exists)
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

    func testNativeHomePausesWirelessDownloadAndRequiresExplicitReconnect() throws {
        guard ProcessInfo.processInfo.environment["FUJI_STUDIO_NATIVE_LIFECYCLE"] == "1" else {
            throw XCTSkip("Enable native lifecycle testing on a suitable simulator.")
        }
        let app = launch(["--fixture-wireless-slow-import"])
        browse(app)
        importPair(app)
        wait { app.staticTexts["cameraImport.status"].label == "Downloading photo 1 of 1" }
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 8))
        app.activate()
        wait { app.staticTexts["cameraImport.status"].label == "Import paused" }
        XCTAssertFalse(app.buttons["cameraImport.resume"].isEnabled)
        XCTAssertEqual(app.staticTexts["cameraImport.counts"].label, "0 of 1 photo imported")
        shot(app, "Wireless import paused after Home")
        app.buttons["cameraImport.done"].tap()
        app.buttons["cameraBrowser.done"].tap()
        XCTAssertTrue(app.buttons["wireless.connect"].isEnabled)
        XCTAssertFalse(app.buttons["wireless.browse"].exists)
        shot(app, "Wireless import requires explicit reconnect after Home")
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
        let retry = app.buttons["cameraImport.retry"]
        XCTAssertTrue(retry.isEnabled)
        retry.tap()
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

    func testAutoSaveGuideShowsOwnershipAndInventoryFailures() {
        for (fixture, guidance) in [
            ("--fixture-wireless-auto-save-ownership-failure", "USB connection could not close"),
            ("--fixture-wireless-auto-save-inventory-failure", "Camera storage could not be read")
        ] {
            let app = launch([fixture])
            openAutoSave(in: app)
            let register = app.buttons["wireless.autoSave.register"]
            XCTAssertTrue(register.waitForExistence(timeout: 5))
            register.tap()
            if fixture.contains("inventory") {
                XCTAssertTrue(app.staticTexts["wireless.autoSave.registered"].waitForExistence(timeout: 5))
                app.buttons["wireless.autoSave.wait"].tap()
            }
            let error = app.staticTexts["wireless.autoSave.failure"]
            XCTAssertTrue(error.waitForExistence(timeout: 5))
            XCTAssertTrue(error.label.contains(guidance))
            XCTAssertFalse(app.buttons["wireless.browse"].exists)
            app.terminate()
        }
    }

    func testAutoSaveFallbackKeepsUnconfirmedCloseAndRetryReachable() {
        let app = launch(["--fixture-wireless-auto-save-close-failure"])
        browse(app)
        let fallback = app.buttons["cameraBrowser.autoSave"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 5))
        fallback.tap()
        XCTAssertTrue(app.navigationBars["Status & settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["wireless.wifiFailure"].exists)
        let disconnect = app.buttons["wireless.disconnect"]
        XCTAssertTrue(disconnect.isEnabled)
        disconnect.tap()
        wait { app.buttons["wireless.autoSave"].exists && app.buttons["wireless.autoSave"].isEnabled }
        app.buttons["wireless.autoSave"].tap()
        XCTAssertTrue(app.staticTexts["wireless.autoSave.unavailable"].waitForExistence(timeout: 5))
    }

    func testRecoveryDistinguishesRepeatedJobsAfterForgettingCamera() throws {
        let app = launch(["--fixture-wireless-recovery-jobs"])
        app.buttons["app.status"].tap()
        let forget = app.buttons["wireless.forget"]
        XCTAssertTrue(forget.waitForExistence(timeout: 5))
        forget.tap()
        app.alerts.buttons["Forget camera"].tap()
        XCTAssertTrue(app.buttons["wireless.pair"].waitForExistence(timeout: 5))
        app.buttons["cameraImport.open"].tap()
        let jobs = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "cameraImport.job."))
        wait { jobs.count == 3 }
        let identifiers = jobs.allElementsBoundByIndex.map(\.identifier)
        let groups = identifiers.map { app.descendants(matching: .any)[$0].firstMatch }
        let labels = groups.map { $0.staticTexts["cameraImport.jobContext"] }
        XCTAssertTrue(labels.allSatisfy(\.exists))
        let xt5 = labels.filter { $0.label.contains("X-T5") }
        XCTAssertEqual(xt5.count, 2)
        XCTAssertEqual(labels.filter { $0.label.hasPrefix("X-E3 · Import") }.count, 1)
        let targetLabel = xt5[0].label
        let otherLabel = xt5[1].label
        XCTAssertTrue(targetLabel.hasPrefix("Fixture X-T5 · Import"))
        XCTAssertNotEqual(targetLabel, otherLabel)
        let target = try XCTUnwrap(groups.first { $0.staticTexts["cameraImport.jobContext"].label == targetLabel })
        let other = try XCTUnwrap(groups.first { $0.staticTexts["cameraImport.jobContext"].label == otherLabel })
        XCTAssertEqual(target.staticTexts["cameraImport.counts"].label, other.staticTexts["cameraImport.counts"].label)
        let retained = target.staticTexts["cameraImport.retainedBytes"].label
        XCTAssertEqual(retained, other.staticTexts["cameraImport.retainedBytes"].label)
        let discard = target.buttons["cameraImport.discard"]
        reveal(discard, in: app)
        discard.tap()
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", targetLabel)).firstMatch.exists)
        app.alerts.buttons["Discard remaining"].tap()
        wait { !discard.exists }
        XCTAssertTrue(other.buttons["cameraImport.discard"].exists)
        XCTAssertEqual(other.staticTexts["cameraImport.retainedBytes"].label, retained)
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
