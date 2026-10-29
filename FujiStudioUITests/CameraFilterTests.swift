import XCTest

@MainActor
final class CameraFilterTests: AppFlowTestCase {
    func testCameraFilterFailureStatusStaysInsideBothLandscapeTrays() {
        let app = launch(["--fixture-filter-sources", "--fixture-filter-unavailable"])
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["workspace.filter"], in: app); app.buttons["filter.compatible"].tap()
        let status = app.staticTexts["filter.unavailable"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation: UIDeviceOrientation in [.landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            wait {
                let window = app.windows.firstMatch.frame, tray = app.collectionViews["photoGrid"].frame
                return window.width > window.height &&
                    (orientation == .landscapeLeft ? tray.minX > window.midX : tray.maxX < window.midX)
            }
            let window = app.windows.firstMatch.frame, tray = app.collectionViews["photoGrid"].frame
            XCTAssertTrue(window.contains(status.frame), "Status must fit the window: \(status.frame)")
            XCTAssertTrue(tray.contains(status.frame), "Status must remain inside the tray: \(status.frame)")
            shot(app, "Camera filter failure status \(orientation.rawValue)")
            let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screen.name = "Camera filter status full screen \(orientation.rawValue)"; screen.lifetime = .keepAlways; add(screen)
        }
    }

    func testCameraFilterMenuUsesConnectedXT5AndRestoresAllPhotos() {
        let app = launch(["--fixture-filter-sources"])
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        XCTAssertEqual(app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@", "grid.source-")).count, 3)
        let filter = app.buttons["workspace.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        tap(filter, in: app)
        let compatible = app.buttons["filter.compatible"]
        XCTAssertTrue(compatible.waitForExistence(timeout: 5))
        XCTAssertTrue(compatible.label.contains("Compatible with X-T5"))
        shot(app, "X-T5 filter menu")
        compatible.tap()
        wait { app.cells["grid.source-0"].exists && !app.cells["grid.source-1"].exists && !app.cells["grid.source-2"].exists }
        XCTAssertTrue(filter.value as? String == "Compatible with X-T5")
        shot(app, "X-T5 compatible photos")
        tap(filter, in: app); app.buttons["filter.all"].tap()
        wait { app.cells["grid.source-1"].exists && app.cells["grid.source-2"].exists }
    }

    func testXE3CameraFilterPrunesBatchAndKeepsViewer() {
        let app = launch(["--fixture-xe3", "--fixture-filter-sources", "--fixture-dark"])
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["workspace.filter"], in: app); app.buttons["filter.compatible"].tap()
        wait { app.cells["grid.source-0"].exists && !app.cells["grid.source-2"].exists }
        tap(app.buttons["workspace.filter"], in: app); app.buttons["filter.all"].tap()
        app.cells["grid.source-0"].tap(); app.buttons["workspace.select"].tap()
        app.cells["grid.source-2"].tap()
        wait { app.staticTexts["workspace.count"].label == "2 selected" }
        tap(app.buttons["workspace.filter"], in: app)
        XCTAssertTrue(app.buttons["filter.compatible"].label.contains("Compatible with X-E3"))
        app.buttons["filter.compatible"].tap()
        wait { app.staticTexts["workspace.count"].label == "1 selected" && !app.cells["grid.source-2"].exists }
        XCTAssertTrue(app.scrollViews["viewer.image"].exists)
        XCTAssertTrue(app.cells["grid.source-0"].exists)
        shot(app, "X-E3 filter in selection dark")
        app.buttons["workspace.select"].tap()
        XCTAssertFalse(app.staticTexts["workspace.count"].exists)
    }

    func testCameraFilterEmptyResultsLeaveMenuReachable() {
        let app = launch()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["workspace.filter"], in: app); app.buttons["filter.compatible"].tap()
        XCTAssertTrue(app.staticTexts["filter.empty"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["workspace.filter"].isHittable)
        shot(app, "Empty camera filter")
        tap(app.buttons["workspace.filter"], in: app); app.buttons["filter.all"].tap()
        XCTAssertTrue(app.cells["grid.source-0"].waitForExistence(timeout: 5))
    }

    func testCameraFilterSitsBesideSelectAndBelowItInLandscape() {
        let app = XCUIApplication(); app.launchArguments = ["--workspace-fixture", "--fixture-filter-sources"]; app.launch()
        XCTAssertTrue(app.buttons["workspace.filter"].waitForExistence(timeout: 10))
        let filter = app.buttons["workspace.filter"], select = app.buttons["workspace.select"]
        XCTAssertEqual(select.frame.minX - filter.frame.maxX, 12, accuracy: 1)
        XCTAssertEqual(filter.frame.midY, select.frame.midY, accuracy: 1)
        select.tap()
        let counter = app.staticTexts["workspace.count"]
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        XCTAssertEqual(counter.frame.minX, 12, accuracy: 1)
        XCTAssertEqual(select.frame.minX - filter.frame.maxX, 12, accuracy: 1)
        app.buttons["drawer.toggle"].tap()
        wait {
            app.buttons["workspace.filter"].frame.maxY < app.cells["grid.source-0"].frame.maxY &&
                app.collectionViews["photoGrid"].frame.minY < 200
        }
        tap(app.buttons["workspace.filter"], in: app)
        XCTAssertTrue(app.buttons["filter.compatible"].waitForExistence(timeout: 5))
        app.buttons["filter.compatible"].tap()
        wait { !app.cells["grid.source-1"].exists }
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation: UIDeviceOrientation in [.landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            wait {
                let window = app.windows.firstMatch.frame, tray = app.collectionViews["photoGrid"].frame
                return window.width > window.height && abs(tray.height - window.height) < 1 &&
                    (orientation == .landscapeLeft ? abs(tray.maxX - window.maxX) < 1 : abs(tray.minX - window.minX) < 1)
            }
            XCTAssertEqual(filter.frame.minY - select.frame.maxY, 12, accuracy: 1)
            XCTAssertGreaterThan(counter.frame.minY, app.windows.firstMatch.frame.midY)
            XCTAssertTrue(filter.isHittable); XCTAssertTrue(select.isHittable)
            let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screen.name = "Filter below Select with counter preserved \(orientation.rawValue)"; screen.lifetime = .keepAlways; add(screen)
            tap(filter, in: app)
            XCTAssertTrue(app.buttons["filter.all"].waitForExistence(timeout: 5))
            app.buttons["filter.compatible"].tap()
        }
    }
}
