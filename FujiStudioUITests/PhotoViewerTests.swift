import XCTest

@MainActor
final class PhotoViewerTests: XCTestCase {
    private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--viewer-fixture"]
        app.launch()
        return app
    }
    private func values(_ app: XCUIApplication) -> [Double] { Array(metrics(app).prefix(3)) }
    private func metrics(_ app: XCUIApplication) -> [Double] {
        let text = app.descendants(matching: .any)["viewer.image"].value as? String ?? ""
        return text.split(separator: ",").compactMap { Double($0) }
    }
    private func image(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["viewer.image"] }
    private func selectVersion(_ identifier: String, in app: XCUIApplication) {
        app.buttons["workspace.versions"].tap()
        XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 5))
        app.buttons[identifier].tap()
    }

    func testZoomPersistsAcrossMatchingVersionsAndResetsForNewSource() throws {
        let app = launch(), viewer = image(app)
        XCTAssertTrue(viewer.waitForExistence(timeout: 10))
        guard viewer.exists else { return }
        viewer.pinch(withScale: 2.5, velocity: 1)
        viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55))
            .press(forDuration: 0.05, thenDragTo: viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)))
        let before = try requiredValues(app)
        XCTAssertEqual(before.count, 3)
        selectVersion("version.saved.11111111-1111-1111-1111-111111111111", in: app)
        let after = try requiredValues(app)
        XCTAssertGreaterThan(before[0], 1.1)
        for i in 0..<3 { XCTAssertEqual(after[i], before[i], accuracy: 0.01) }
        app.buttons["fixture.nextSource"].tap()
        let reset = try requiredValues(app)
        XCTAssertEqual(reset[0], 1, accuracy: 0.01)
    }

    private func requiredValues(_ app: XCUIApplication) throws -> [Double] {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let measured = self.metrics(app)
            return measured.count == 5 && measured.allSatisfy(\.isFinite)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, "Viewer must publish all finite metrics after version/source changes")
        let measured = metrics(app)
        return try XCTUnwrap(measured.count == 5 && measured.allSatisfy(\.isFinite) ? Array(measured.prefix(3)) : nil, "Missing or malformed viewer metrics")
    }

    func testPinchMaximumZoomPanViewportResizeAndDoubleTapFit() {
        let app = launch(), viewer = image(app)
        XCTAssertTrue(viewer.waitForExistence(timeout: 10))
        guard viewer.exists else { return }
        viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)).doubleTap()
        XCTAssertEqual(values(app).first ?? 0, 2, accuracy: 0.01)
        XCTAssertEqual(values(app).dropFirst().first ?? 0, 0.65, accuracy: 0.02)
        viewer.doubleTap()
        XCTAssertEqual(values(app).first ?? 0, 1, accuracy: 0.01)
        for id in ["viewer.zoomOut", "viewer.fit", "viewer.zoomIn"] { XCTAssertFalse(app.buttons[id].exists) }
        viewer.pinch(withScale: 4, velocity: 2)
        viewer.pinch(withScale: 4, velocity: 2)
        XCTAssertEqual(values(app).first ?? 0, 8, accuracy: 0.01)
        viewer.swipeLeft(); viewer.swipeUp()
        let before = values(app)
        let portraitSize = viewer.frame.size
        app.buttons["fixture.resize"].tap()
        let resized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in viewer.frame.size != portraitSize }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [resized], timeout: 8), .completed, "Fixture must resize the actual scroll view")
        let measured = metrics(app)
        XCTAssertEqual(measured.count, 5)
        if measured.count == 5 {
            XCTAssertEqual(measured[3], viewer.frame.width, accuracy: 0.5)
            XCTAssertEqual(measured[4], viewer.frame.height, accuracy: 0.5)
        }
        let after = values(app)
        XCTAssertEqual(after.first ?? 0, 8, accuracy: 0.01)
        if before.count == 3, after.count == 3 {
            XCTAssertEqual(before[1], after[1], accuracy: 0.03)
            XCTAssertEqual(before[2], after[2], accuracy: 0.03)
            XCTAssertTrue((0...1).contains(after[1]) && (0...1).contains(after[2]))
        }
        XCTAssertTrue(viewer.wait(for: \.label, toEqual: "Photo, detail loaded", timeout: 10))
        let measurement = XCTAttachment(string: "Before: \(before); after: \(after); debug bounds: \(measured); element frame: \(viewer.frame)")
        measurement.name = "Normalized inspection and actual bounds"; measurement.lifetime = .keepAlways; add(measurement)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Detailed image at 8x after viewport resize"; attachment.lifetime = .keepAlways; add(attachment)
        viewer.doubleTap()
        XCTAssertEqual(values(app).first ?? 0, 1, accuracy: 0.01)
    }

    /// Retained strict device gate. The available environment did not demonstrate a native
    /// interface rotation; viewport-resize software evidence is a separate test above.
    func testNativeDeviceRotationPreservesInspection() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FUJI_STUDIO_NATIVE_ROTATION"] == "1",
            "Native device rotation remains an unverified device gate; enable explicitly on a suitable runtime/device.")
        let app = launch(), viewer = image(app)
        XCTAssertTrue(viewer.waitForExistence(timeout: 10))
        viewer.doubleTap()
        let before = values(app), size = viewer.frame.size
        XCUIDevice.shared.orientation = .landscapeLeft
        let resized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in viewer.frame.size != size }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [resized], timeout: 8), .completed, "Native rotation must resize the actual viewport")
        let after = values(app)
        XCTAssertEqual(before.count, 3); XCTAssertEqual(after.count, 3)
        for i in 0..<min(before.count, after.count) { XCTAssertEqual(after[i], before[i], accuracy: 0.03) }
    }

    func testZoomSurvivesUnavailableVersionAndFullDetailReturns() {
        let app = launch(), viewer = image(app)
        XCTAssertTrue(viewer.waitForExistence(timeout: 10))
        guard viewer.exists else { return }
        viewer.doubleTap()
        let before = values(app)
        selectVersion("version.raw", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["viewer.unavailable"].waitForExistence(timeout: 3))
        selectVersion("version.cameraJPEG", in: app)
        let after = values(app)
        XCTAssertEqual(before.count, 3); XCTAssertEqual(after.count, 3)
        for index in 0..<min(before.count, after.count) { XCTAssertEqual(after[index], before[index], accuracy: 0.01) }
        XCTAssertTrue(viewer.wait(for: \.label, toEqual: "Photo, detail loaded", timeout: 10))
    }

    func testUnavailableRAWAndManualVersionResistsLatePreview() {
        let app = launch()
        XCTAssertTrue(image(app).waitForExistence(timeout: 10))
        guard image(app).exists else { return }
        selectVersion("version.raw", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["viewer.unavailable"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["viewer.unavailable"].label.contains("RAW display unavailable"))
        selectVersion("version.cameraJPEG", in: app)
        app.buttons["fixture.latePreview"].tap()
        XCTAssertEqual(app.staticTexts["fixture.selection"].label, "Original camera JPEG")
        XCTAssertEqual(app.staticTexts["fixture.recipe"].label, "Selected recipe: C3 Fixture recipe")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Full detailed fixture fit"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
