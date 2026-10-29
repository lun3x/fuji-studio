import XCTest

@MainActor final class AppFlowTests: XCTestCase {
    func testXE3RAWDisplayFailureKeepsPairedJPEGAndConversionAvailable() {
        let app=launch(["--fixture-xe3","--fixture-raw-unavailable"])
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        app.cells["grid.source-0"].tap()
        tap(app.buttons["workspace.versions"],in:app);app.buttons["version.raw"].tap()
        let unavailable=app.descendants(matching:.any)["viewer.unavailable"]
        XCTAssertTrue(unavailable.waitForExistence(timeout:5))
        XCTAssertTrue(unavailable.label.contains("Camera conversion is still available"))
        shot(app,"X-E3 RAW unavailable with explicit JPEG choice")
        tap(app.buttons["workspace.versions"],in:app);app.buttons["version.cameraJPEG"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout:5))
        recipe(4,in:app);wait { app.buttons["workspace.export"].isEnabled }
        app.buttons["workspace.export"].tap()
        wait { app.buttons["app.status"].label.contains("1 saved") }
        tap(app.buttons["recipe.control"],in:app);app.buttons["recipe.none"].tap()
        tap(app.buttons["workspace.versions"],in:app)
        let saved=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","version.saved.")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout:5));saved.tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout:5))
        shot(app,"X-E3 conversion and saved version after RAW decoder failure")
    }
    func testXE3EditorAtLargestTextRemainsUsableInLandscape() {
        let app=launch(["--fixture-xe3","--fixture-accessibility"])
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["recipe.control"],in:app);app.buttons["recipe.copy.1"].tap()
        let edit=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","recipe.edit.")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout:5));edit.tap()
        XCTAssertTrue(app.buttons["recipe.editor.save"].waitForExistence(timeout:5))
        shot(app,"X-E3 editor largest text portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        wait {
            let window=app.windows.firstMatch.frame,save=app.buttons["recipe.editor.save"].frame
            return window.width > window.height && save.maxX > window.width/2 && save.maxX <= window.maxX
        }
        XCTAssertTrue(app.buttons["recipe.editor.save"].isHittable)
        XCTAssertTrue(app.buttons["recipe.editor.cancel"].isHittable)
        let landscape=XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        landscape.name="X-E3 editor largest text landscape full screen";landscape.lifetime = .keepAlways;add(landscape)
        app.buttons["recipe.editor.cancel"].tap()
    }
    func testXE3EditorUsesCameraCapabilitiesAndDiscreteKelvin() {
        let app=launch(["--fixture-xe3"])
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["recipe.control"],in:app);app.buttons["recipe.copy.4"].tap()
        let edit=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","recipe.edit.")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout:5));edit.tap()
        let grain=app.buttons["recipe.editor.setting.grainEffect"]
        XCTAssertTrue(grain.waitForExistence(timeout:5))
        XCTAssertFalse(app.buttons["recipe.editor.setting.grainSize"].exists)
        XCTAssertFalse(app.buttons["recipe.editor.setting.colorChrome"].exists)
        XCTAssertFalse(app.buttons["recipe.editor.setting.clarity"].exists)
        let kelvin=app.buttons["recipe.editor.setting.kelvin"]
        reveal(kelvin,in:app);kelvin.tap();app.buttons["7100"].tap()
        shot(app,"X-E3 semantic editor and verified Kelvin")
        app.buttons["recipe.editor.save"].tap()
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout:5))
        edit.tap();reveal(kelvin,in:app);XCTAssertTrue(kelvin.label.contains("7100"))
        app.buttons["recipe.editor.cancel"].tap()
    }
    func testDeclaredThreeSlotsHaveNoInventedExtraRows() {
        let app=launch(["--fixture-xe3","--fixture-three-slots"])
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["recipe.control"],in:app)
        for slot in 1...3 { XCTAssertTrue(app.buttons["recipe.slot.\(slot)"].exists) }
        for slot in 4...7 { XCTAssertFalse(app.buttons["recipe.slot.\(slot)"].exists) }
        shot(app,"Three declared recipe slots")
    }
    func testOtherModelPhoneRecipeStaysVisibleAndEditable() {
        let app=launch(["--fixture-xe3","--fixture-mixed-models"])
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["recipe.control"],in:app)
        app.segmentedControls["recipe.collection"].buttons["Phone"].tap()
        let phone=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","recipe.phone.")).firstMatch
        XCTAssertTrue(phone.exists);XCTAssertFalse(phone.isEnabled)
        XCTAssertTrue(phone.label.contains("X-T5"))
        let edit=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","recipe.edit.")).firstMatch
        XCTAssertTrue(edit.isEnabled);edit.tap()
        XCTAssertTrue(app.textFields["recipe.editor.name"].waitForExistence(timeout:5))
        replaceText(app.textFields["recipe.editor.name"],with:"Other model offline edit")
        app.buttons["recipe.editor.save"].tap()
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout:5))
        XCTAssertTrue(phone.label.contains("Other model offline edit"));XCTAssertFalse(phone.isEnabled)
        shot(app,"Other Fujifilm model remains editable")
    }
    func testPhoneEditorGrainEffectAndSizeSaveIndependently() {
        let app = launch(["--fixture-disconnected-camera"])
        tap(app.buttons["recipe.control"], in: app); app.buttons["recipe.copy.3"].tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.edit.")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        let effect = app.buttons["recipe.editor.setting.grainEffect"]
        let size = app.buttons["recipe.editor.setting.grainSize"]
        XCTAssertTrue(effect.waitForExistence(timeout: 5))
        reveal(effect, in: app); effect.tap(); app.buttons["Weak"].tap()
        XCTAssertTrue(size.isEnabled)
        size.tap(); app.buttons["Large"].tap()
        effect.tap(); app.buttons["Off"].tap()
        XCTAssertFalse(size.isEnabled); XCTAssertTrue(size.label.contains("Large"))
        shot(app, "Grain Off disables size and retains Large")
        effect.tap(); app.buttons["Strong"].tap()
        XCTAssertTrue(size.isEnabled); XCTAssertTrue(size.label.contains("Large"))
        app.buttons["recipe.editor.save"].tap()
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout: 5))
        edit.tap(); reveal(effect, in: app)
        XCTAssertTrue(effect.label.contains("Strong")); XCTAssertTrue(size.label.contains("Large"))
        effect.tap(); app.buttons["Off"].tap(); app.buttons["recipe.editor.save"].tap()
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout: 5))
        edit.tap(); reveal(effect, in: app)
        XCTAssertTrue(effect.label.contains("Off")); XCTAssertFalse(size.isEnabled)
        XCTAssertTrue(size.label.contains("Large"))
        effect.tap(); app.buttons["Weak"].tap()
        XCTAssertTrue(size.isEnabled); XCTAssertTrue(size.label.contains("Large"))
        size.tap(); app.buttons["Small"].tap()
        XCTAssertTrue(effect.label.contains("Weak")); XCTAssertTrue(size.label.contains("Small"))
        app.buttons["recipe.editor.cancel"].tap()
    }

    private func replaceText(_ field: XCUIElement, with value: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + value)
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 { if element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    func testPhoneEditorSavesNameAndFilmOfflineAndCancelDiscardsChanges() {
        let app = launch(["--fixture-disconnected-camera"])
        tap(app.buttons["recipe.control"], in: app); app.buttons["recipe.copy.3"].tap()
        let phoneQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.phone."))
        XCTAssertTrue(phoneQuery.firstMatch.waitForExistence(timeout: 5))
        let id = phoneQuery.firstMatch.identifier
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.edit.")).firstMatch
        XCTAssertTrue(edit.isEnabled); XCTAssertFalse(phoneQuery.firstMatch.isEnabled)
        edit.tap()
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForExistence(timeout: 5))
        replaceText(app.textFields["recipe.editor.name"], with: "My Provia")
        app.buttons["recipe.editor.setting.film"].tap()
        app.buttons["PROVIA / Standard"].tap()
        shot(app, "Phone editor name and film draft")
        app.buttons["recipe.editor.save"].tap()
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons[id].label.contains("My Provia"))
        XCTAssertFalse(app.buttons[id].isEnabled)
        edit.tap()
        XCTAssertEqual(app.textFields["recipe.editor.name"].value as? String, "My Provia")
        let film = app.buttons["recipe.editor.setting.film"]
        XCTAssertTrue(film.label.contains("PROVIA") || (film.value as? String ?? "").contains("PROVIA"))
        replaceText(app.textFields["recipe.editor.name"], with: "Discard me")
        app.buttons["recipe.editor.cancel"].tap()
        XCTAssertTrue(app.buttons[id].label.contains("My Provia"))
        XCTAssertEqual(phoneQuery.count, 1)
    }

    func testPhoneEditorRejectsInvalidTemperatureAndKeepsDraft() {
        let app = launch(["--fixture-disconnected-camera"])
        tap(app.buttons["recipe.control"], in: app); app.buttons["recipe.copy.3"].tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.edit.")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.tap()
        let balance = app.buttons["recipe.editor.setting.whiteBalance"]
        reveal(balance, in: app); balance.tap(); app.buttons["Colour temperature"].tap()
        let temperature = app.textFields["recipe.editor.temperature"]
        reveal(temperature, in: app); replaceText(temperature, with: "10001")
        shot(app, "Phone editor temperature draft before validation")
        app.buttons["recipe.editor.save"].tap()
        XCTAssertTrue(app.staticTexts["recipe.editor.error"].waitForExistence(timeout: 5))
        XCTAssertEqual(temperature.value as? String, "10001")
        replaceText(temperature, with: "5200")
        app.buttons["recipe.editor.save"].tap()
        XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForNonExistence(timeout: 5))
        edit.tap(); reveal(app.buttons["recipe.editor.setting.whiteBalance"], in: app)
        XCTAssertEqual(app.textFields["recipe.editor.temperature"].value as? String, "5200")
    }

    func testPhoneEditorAtLargestTextHasUsableSaveAndCancel() {
        let app = launch(["--fixture-disconnected-camera", "--fixture-accessibility"])
        tap(app.buttons["recipe.control"], in: app); app.buttons["recipe.copy.1"].tap()
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.edit.")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); XCTAssertGreaterThanOrEqual(edit.frame.width, 44)
        edit.tap(); XCTAssertTrue(app.navigationBars["Edit phone recipe"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.textFields["recipe.editor.name"].frame.height, 44,
                             "The editor must inherit the largest accessibility text size")
        let effect = app.buttons["recipe.editor.setting.grainEffect"]
        reveal(effect, in: app); effect.tap(); app.buttons["Off"].tap()
        let size = app.buttons["recipe.editor.setting.grainSize"]
        reveal(size, in: app); XCTAssertFalse(size.isEnabled)
        shot(app, "Phone editor at largest text")
        XCTAssertTrue(app.buttons["recipe.editor.save"].isHittable)
        XCTAssertTrue(app.buttons["recipe.editor.cancel"].isHittable)
        app.buttons["recipe.editor.cancel"].tap()
    }
    private func launch(_ flags: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--ui-fixtures"] + flags; app.launch()
        XCTAssertTrue(app.buttons["workspace.select"].waitForExistence(timeout: 10))
        return app
    }
    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        let rect = element.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.midX, dy: rect.midY)).tap()
    }
    private func recipe(_ slot: Int, in app: XCUIApplication) {
        tap(app.buttons["recipe.control"], in: app)
        XCTAssertTrue(app.buttons["recipe.slot.\(slot)"].waitForExistence(timeout: 5))
        tap(app.buttons["recipe.slot.\(slot)"], in: app)
    }
    private func clearRecipe(in app: XCUIApplication) {
        tap(app.buttons["recipe.control"], in: app)
        XCTAssertTrue(app.buttons["recipe.none"].waitForExistence(timeout: 5))
        tap(app.buttons["recipe.none"], in: app)
    }
    private func version(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        if app.buttons["workspace.versions"].exists { app.buttons["workspace.versions"].tap() }
        let button = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", identifier)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5)); return button
    }
    private func wait(_ condition: @escaping () -> Bool) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 10), .completed)
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        let export = app.buttons["workspace.export"]
        let bounds = XCTAttachment(string: "Status \(app.buttons["app.status"].frame); Recipe \(app.buttons["recipe.control"].frame); Export \(export.exists ? String(describing: export.frame) : "hidden"); Grid \(app.collectionViews["photoGrid"].frame)")
        bounds.name = name + " bounds"; bounds.lifetime = .keepAlways; add(bounds)
    }
    private func selectFirstRow(_ app: XCUIApplication) {
        app.buttons["workspace.select"].tap()
        app.cells["grid.source-0"].tap() // Clear the viewed seed before an additive sweep.
        let start = app.cells["grid.source-0"].coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.65))
        let end = app.cells["grid.source-2"].coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.65))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
    func testRecipeSelectionReplacesVersionsWithExport() {
        let app = launch()
        app.cells["grid.source-0"].tap()
        let versions = app.buttons["workspace.versions"], export = app.buttons["workspace.export"]
        XCTAssertTrue(versions.waitForExistence(timeout: 5))
        XCTAssertFalse(export.exists)
        let versionFrame = versions.frame
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        XCTAssertFalse(export.exists)
        recipe(3, in: app)
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        XCTAssertFalse(versions.exists)
        XCTAssertFalse(app.scrollViews["version.options"].exists)
        XCTAssertEqual(export.frame, versionFrame)
        wait { export.isEnabled }
        shot(app, "Recipe replaces version selector with floating export")
        export.tap()
        wait { app.buttons["app.status"].label.contains("1 saved") }
        XCTAssertFalse(versions.exists)
        tap(app.buttons["recipe.control"], in: app)
        tap(app.buttons["recipe.none"], in: app)
        XCTAssertTrue(versions.waitForExistence(timeout: 5))
        XCTAssertFalse(export.exists)
        XCTAssertEqual(versions.frame, versionFrame)
        versions.tap()
        XCTAssertTrue(app.buttons["version.raw"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["version.cameraJPEG"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "version.saved.")).firstMatch.exists)
        XCTAssertFalse(app.buttons["version.preview"].exists)
        shot(app, "Clearing recipe restores original and saved versions")
    }
    func testExportStaysDisabledUntilPreviewFinishesDespiteCameraReadyUpdates() {
        let app = launch(["--fixture-held-preview"])
        app.cells["grid.source-0"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(3, in: app)
        let export = app.buttons["workspace.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        wait { app.buttons["fixture.finishPreview"].value as? String == "Loading preview" }
        XCTAssertFalse(export.isEnabled, "Export starts grey while the preview is being prepared")
        for _ in 0..<3 {
            app.buttons["fixture.cycleCamera"].tap()
            wait { app.buttons["app.status"].label.contains("Camera ready") }
            XCTAssertFalse(export.isEnabled, "A ready camera must not enable export before the preview is loaded")
        }
        shot(app, "Export stays grey while preview is loading")
        app.buttons["fixture.finishPreview"].tap()
        wait { export.isEnabled }
        XCTAssertTrue(app.scrollViews["viewer.image"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["viewer.status"].exists)
        shot(app, "Export becomes blue when preview is ready")
        tap(export, in: app)
        wait { app.buttons["app.status"].label.contains("1 saved") }
    }
    func testInjectedFlowOpensRealWorkspaceWithoutSystemPermissions() {
        let app = launch()
        XCTAssertFalse(app.buttons["app.connect"].exists)
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
        app.cells["grid.source-0"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["workspace.export"].exists)
        shot(app, "Automatically connected paired original")
    }
    func testInitiallyInactiveStartupWaitsForForegroundBeforeConnecting() {
        let app = launch(["--fixture-initial-inactive", "--fixture-scene-controls"])
        XCTAssertFalse(app.buttons["app.connect"].exists)
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.staticTexts["app.camera"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["app.camera"].label.contains("Plug in a supported Fujifilm camera"), app.staticTexts["app.camera"].label)
        app.buttons["Done"].tap()
        app.buttons["fixture.foreground"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
    }
    func testPhotoChangeKeepsPreviousImageAndZoomUnderLoadingOverlay() {
        let app = launch(["--fixture-held-photo"])
        app.cells["grid.source-0"].tap()
        let viewer = app.scrollViews["viewer.image"], loading = app.descendants(matching: .any)["viewer.loading"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        wait { !loading.exists }
        viewer.pinch(withScale: 2, velocity: 1)
        func zoom() -> Double { Double((viewer.value as? String ?? "").split(separator: ",").first ?? "") ?? -1 }
        let frame = viewer.frame, previousZoom = zoom()
        XCTAssertGreaterThan(previousZoom, 1.1)
        app.cells["grid.source-2"].tap()
        XCTAssertTrue(loading.waitForExistence(timeout: 5))
        XCTAssertTrue(viewer.exists)
        XCTAssertEqual(viewer.frame, frame)
        XCTAssertEqual(zoom(), previousZoom, accuracy: 0.01)
        XCTAssertEqual(loading.frame.midX, frame.midX, accuracy: 1)
        XCTAssertEqual(loading.frame.midY, frame.midY, accuracy: 1)
        shot(app, "Previous photo greyed under photo-switch spinner")
        app.buttons["fixture.finishPhoto"].tap()
        wait { !loading.exists && abs(zoom() - 1) < 0.01 }
        XCTAssertFalse(app.descendants(matching: .any)["viewer.unavailable"].exists)
        shot(app, "New photo replaces previous photo at fit")
    }
    func testDisconnectedRecipeMenuSelectsNoneAndDisablesCachedRecipesAndRefresh() {
        let app = launch(["--fixture-disconnected-camera"])
        tap(app.buttons["recipe.control"], in: app)
        let none = app.buttons["recipe.none"]
        XCTAssertTrue(none.waitForExistence(timeout: 5))
        XCTAssertTrue(none.isSelected)
        XCTAssertTrue(none.isEnabled)
        for slot in 1...7 {
            let option = app.buttons["recipe.slot.\(slot)"]
            XCTAssertTrue(option.exists)
            XCTAssertFalse(option.isEnabled)
            XCTAssertFalse(option.isSelected)
        }
        XCTAssertFalse(app.buttons["recipe.refresh"].isEnabled)
        shot(app, "Disconnected recipes are greyed out with No recipe selected")
        tap(none, in: app)
        app.buttons["fixture.plugInCamera"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["recipe.control"], in: app)
        XCTAssertTrue(none.waitForExistence(timeout: 5))
        XCTAssertTrue(none.isSelected)
        for slot in 1...6 { XCTAssertTrue(app.buttons["recipe.slot.\(slot)"].isEnabled) }
        XCTAssertFalse(app.buttons["recipe.slot.7"].isEnabled)
        XCTAssertTrue(app.buttons["recipe.refresh"].isEnabled)
    }

    func testOfflineCameraCopyAppearsOnPhoneButRequiresCameraForSelection() {
        let app = launch(["--fixture-disconnected-camera"])
        app.cells["grid.source-0"].tap()
        tap(app.buttons["recipe.control"], in: app)
        let tabs = app.segmentedControls["recipe.collection"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        tabs.buttons["Phone"].tap()
        XCTAssertTrue(app.staticTexts["recipe.phone.empty"].waitForExistence(timeout: 5))
        shot(app, "Phone recipes empty state")
        tabs.buttons["Camera"].tap()
        let copy = app.buttons["recipe.copy.3"]
        XCTAssertTrue(copy.isEnabled, "Copying cached recipes works offline")
        XCTAssertFalse(app.buttons["recipe.slot.3"].isEnabled)
        copy.tap()
        let phone = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.phone.")).firstMatch
        XCTAssertTrue(phone.waitForExistence(timeout: 5))
        XCTAssertTrue(tabs.buttons["Phone"].isSelected)
        XCTAssertFalse(phone.isSelected)
        XCTAssertTrue(app.buttons["recipe.none"].isSelected)
        XCTAssertEqual(app.buttons["recipe.control"].label, "No recipe selected")
        shot(app, "Camera recipe saved on phone without changing selection")
        tabs.buttons["Camera"].tap()
        copy.tap()
        XCTAssertTrue(phone.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.phone.")).count, 1)
        XCTAssertFalse(phone.isEnabled)
        tap(app.buttons["recipe.none"], in: app)
        app.buttons["fixture.plugInCamera"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["recipe.control"], in: app)
        tabs.buttons["Phone"].tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.phone.")).count, 1)
        XCTAssertTrue(phone.isEnabled)
        phone.tap()
        XCTAssertTrue(app.buttons["workspace.export"].waitForExistence(timeout: 5))
        wait { app.buttons["workspace.export"].isEnabled }
        shot(app, "Saved phone recipe selected with camera ready")
    }

    func testPhoneRecipeCopyAndDeletionAtLargestText() {
        let app = launch(["--fixture-accessibility", "--fixture-disconnected-camera"])
        tap(app.buttons["recipe.control"], in: app)
        let copy = app.buttons["recipe.copy.1"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(copy.frame.width, 44)
        XCTAssertGreaterThanOrEqual(copy.frame.height, 44)
        shot(app, "Camera recipe copy controls at largest text")
        copy.tap()
        let phone = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.phone.")).firstMatch
        XCTAssertTrue(phone.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(phone.frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["recipe.none"].frame.minY, app.scrollViews["recipe.options"].frame.minY,
            "Switching collections starts at the top even after the camera list scrolls")
        shot(app, "Phone recipe at largest text")
        XCTAssertFalse(phone.isEnabled)
        let delete = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.delete.")).firstMatch
        XCTAssertTrue(delete.isEnabled)
        XCTAssertGreaterThanOrEqual(delete.frame.width, 44)
        XCTAssertGreaterThanOrEqual(delete.frame.height, 44)
        delete.tap()
        XCTAssertTrue(app.alerts["Delete phone recipe?"].waitForExistence(timeout: 5))
        shot(app, "Phone recipe delete confirmation at largest text")
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["recipe.phone.empty"].waitForExistence(timeout: 5))
    }

    func testOfflinePhoneDeletionCanBeCancelledConfirmedAndRecopied() {
        let app = launch(["--fixture-disconnected-camera"])
        tap(app.buttons["recipe.control"], in: app)
        app.buttons["recipe.copy.3"].tap()
        let phoneQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.phone."))
        XCTAssertTrue(phoneQuery.firstMatch.waitForExistence(timeout: 5))
        let originalIdentifier = phoneQuery.firstMatch.identifier
        XCTAssertFalse(phoneQuery.firstMatch.isEnabled)
        let delete = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.delete.")).firstMatch
        XCTAssertTrue(delete.isEnabled)
        shot(app, "Disconnected phone recipe greyed with delete enabled")
        delete.tap()
        XCTAssertTrue(app.alerts["Delete phone recipe?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons[originalIdentifier].exists)
        delete.tap()
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(app.buttons[originalIdentifier].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["recipe.phone.empty"].exists)
        XCTAssertTrue(app.buttons["recipe.none"].isSelected)
        app.segmentedControls["recipe.collection"].buttons["Camera"].tap()
        app.buttons["recipe.copy.3"].tap()
        XCTAssertTrue(phoneQuery.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(phoneQuery.firstMatch.identifier, originalIdentifier)
        XCTAssertEqual(phoneQuery.count, 1)
    }

    func testDeletingSelectedPhoneRecipeClearsSelectionAndRestoresVersionsControl() {
        let app = launch()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        app.cells["grid.source-0"].tap()
        tap(app.buttons["recipe.control"], in: app)
        app.buttons["recipe.copy.3"].tap()
        let phone = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.phone.")).firstMatch
        XCTAssertTrue(phone.waitForExistence(timeout: 5))
        phone.tap()
        wait { app.buttons["workspace.export"].isEnabled }
        tap(app.buttons["recipe.control"], in: app)
        XCTAssertTrue(app.segmentedControls["recipe.collection"].buttons["Phone"].isSelected)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recipe.delete.")).firstMatch.tap()
        app.alerts.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["recipe.phone.empty"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["recipe.none"].isSelected)
        XCTAssertEqual(app.buttons["recipe.control"].label, "No recipe selected")
        XCTAssertFalse(app.buttons["workspace.export"].exists)
        XCTAssertTrue(app.buttons["workspace.versions"].exists)
        shot(app, "Deleting selected phone recipe restores versions")
    }
    private func assertFloatingPhotoControls(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let status = app.buttons["app.status"], recipe = app.buttons["recipe.control"], versions = app.buttons["workspace.versions"]
        let viewer = app.scrollViews["viewer.image"]
        for control in [status, recipe, versions] {
            XCTAssertGreaterThanOrEqual(control.frame.height, 44, file: file, line: line)
            XCTAssertGreaterThanOrEqual(control.frame.width, 44, file: file, line: line)
            XCTAssertEqual(control.frame.minY, status.frame.minY, accuracy: 1, file: file, line: line)
            XCTAssertGreaterThanOrEqual(control.frame.minY, viewer.frame.minY, file: file, line: line)
            XCTAssertLessThanOrEqual(control.frame.maxY, viewer.frame.maxY, file: file, line: line)
            XCTAssertGreaterThanOrEqual(control.frame.minX, app.frame.minX, file: file, line: line)
            XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX, file: file, line: line)
        }
        XCTAssertEqual(status.frame.minX, viewer.frame.minX + 16, accuracy: 1, file: file, line: line)
        XCTAssertEqual(status.frame.minY, viewer.frame.minY + 8, accuracy: 1, file: file, line: line)
        XCTAssertEqual(versions.frame.maxX, viewer.frame.maxX - 16, accuracy: 1, file: file, line: line)
        XCTAssertEqual(recipe.frame.maxX + 8, versions.frame.minX, accuracy: 1, file: file, line: line)
        XCTAssertFalse(app.buttons["app.connect"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["workspace.export"].exists, file: file, line: line)
        XCTAssertFalse(app.staticTexts["Fuji Studio"].exists, file: file, line: line)
    }
    func testFloatingStatusAndRightAlignedPhotoControlsGiveSpaceBackToPhoto() {
        let app = launch()
        app.cells["grid.source-0"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout: 5))
        assertFloatingPhotoControls(app)
        XCTAssertEqual(app.buttons["app.status"].frame.width, app.buttons["workspace.versions"].frame.width, accuracy: 1)
        XCTAssertEqual(app.buttons["app.status"].frame.height, app.buttons["workspace.versions"].frame.height, accuracy: 1)
        tap(app.buttons["app.status"], in: app)
        XCTAssertTrue(app.staticTexts["app.access"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        assertFloatingPhotoControls(app)
        shot(app, "Floating camera icon and right-aligned recipe and versions over photo")
    }
    func testCameraIndicatorStaysPreparingThroughoutRecipeImport() {
        let app = launch(["--fixture-disconnected-camera", "--fixture-held-recipes"])
        let status = app.buttons["app.status"]
        guard status.value as? String == "Camera disconnected" else {
            XCTFail("The disconnected indicator must expose the no-camera state")
            return
        }
        app.cells["grid.source-0"].tap()
        let versions = app.buttons["workspace.versions"]
        XCTAssertTrue(versions.waitForExistence(timeout: 5))
        wait { app.scrollViews["viewer.image"].exists && !app.descendants(matching: .any)["viewer.loading"].exists }
        let frame = status.frame
        XCTAssertEqual(frame.width, versions.frame.width, accuracy: 1)
        XCTAssertEqual(frame.height, versions.frame.height, accuracy: 1)
        shot(app, "Crossed-out camera before connection")
        app.buttons["fixture.plugInCamera"].tap()
        wait { status.value as? String == "Preparing camera" }
        for _ in 0..<3 {
            app.buttons["fixture.cycleRecipeCamera"].tap()
            XCTAssertEqual(status.value as? String, "Preparing camera", "Busy/ready updates must not interrupt recipe-loading presentation")
            XCTAssertEqual(status.frame, frame)
        }
        shot(app, "Spinning camera while recipes download")
        app.buttons["fixture.finishRecipes"].tap()
        wait { status.value as? String == "Camera ready" }
        XCTAssertEqual(status.frame, frame)
        shot(app, "Ready camera after recipe download")
    }
    func testFloatingVersionsMenuReclaimsPhotoSpaceAndSwitchesWithoutExport() {
        let app = launch()
        app.cells["grid.source-0"].tap()
        let viewer = app.scrollViews["viewer.image"], versions = app.buttons["workspace.versions"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        for id in ["viewer.zoomOut", "viewer.fit", "viewer.zoomIn"] { XCTAssertFalse(app.buttons[id].exists) }
        XCTAssertEqual(viewer.frame.maxY, app.buttons["drawer.toggle"].frame.minY, accuracy: 1, "The photo should reach the tray without reserved control rows")
        XCTAssertTrue(versions.exists)
        guard versions.exists else { return }
        XCTAssertGreaterThanOrEqual(versions.frame.minY, viewer.frame.minY - 0.5)
        XCTAssertLessThanOrEqual(versions.frame.maxY, viewer.frame.maxY)
        XCTAssertEqual(versions.frame.maxX, viewer.frame.maxX - 16, accuracy: 1)
        XCTAssertFalse(versions.frame.intersects(app.buttons["recipe.control"].frame))
        XCTAssertFalse(app.buttons["version.cameraJPEG"].exists, "Versions appear only in the menu")
        versions.tap()
        let raw = app.buttons["version.raw"], jpeg = app.buttons["version.cameraJPEG"]
        XCTAssertTrue(jpeg.waitForExistence(timeout: 5))
        XCTAssertTrue(jpeg.isSelected)
        XCTAssertGreaterThanOrEqual(jpeg.frame.minY, raw.frame.maxY)
        raw.tap()
        wait { versions.value as? String == "RAW" }
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        XCTAssertFalse(raw.exists)
        versions.tap(); app.buttons["version.cameraJPEG"].tap()
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        let before = versions.value as? String
        versions.tap()
        viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8)).tap()
        XCTAssertFalse(app.buttons["version.raw"].exists)
        XCTAssertEqual(versions.value as? String, before)
        XCTAssertFalse(app.buttons["workspace.export"].exists)
        shot(app, "Floating versions and photo without bottom controls")
    }
    func testFloatingSelectionEntersAndCancelsWithoutMovingPhotos() {
        let app = launch()
        let select = app.buttons["workspace.select"], grid = app.collectionViews["photoGrid"]
        XCTAssertFalse(app.buttons["workspace.all"].exists)
        XCTAssertFalse(app.buttons["workspace.none"].exists)
        XCTAssertFalse(app.staticTexts["workspace.count"].exists)
        XCTAssertEqual(select.label, "Select")
        XCTAssertGreaterThanOrEqual(select.frame.minY, grid.frame.minY)
        XCTAssertEqual(select.frame.maxX, grid.frame.maxX - 12, accuracy: 1)
        app.cells["grid.source-0"].tap()
        let frame = app.cells["grid.source-0"].frame
        select.tap()
        XCTAssertEqual(select.label, "Cancel selection")
        XCTAssertEqual(app.cells["grid.source-0"].frame, frame)
        XCTAssertTrue(app.cells["grid.source-0"].isSelected)
        app.cells["grid.source-1"].tap()
        XCTAssertEqual(app.staticTexts["workspace.count"].label, "2 selected")
        shot(app, "Photos-style floating cancel and checked photos")
        select.tap()
        XCTAssertEqual(select.label, "Select")
        XCTAssertEqual(app.cells["grid.source-0"].frame, frame)
        XCTAssertFalse(app.cells["grid.source-0"].isSelected)
        XCTAssertFalse(app.cells["grid.source-1"].isSelected)
        XCTAssertFalse(app.staticTexts["workspace.count"].exists)
        shot(app, "Photos-style floating Select in browse")
    }
    func testLargestTextVersionMenuScrollsToFullSavedLabel() {
        let app = launch(["--fixture-accessibility"])
        app.cells["grid.source-0"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout: 5))
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(1, in: app)
        wait { app.buttons["workspace.export"].isEnabled }
        tap(app.buttons["workspace.export"], in: app)
        wait { app.buttons["app.status"].label.contains("1 saved") }
        clearRecipe(in: app)
        let saved = version("version.saved.", in: app)
        let options = app.scrollViews["version.options"]
        for _ in 0..<12 {
            if saved.frame.minY >= options.frame.minY && saved.frame.maxY <= options.frame.maxY { break }
            let targetAbove = saved.frame.minY < options.frame.minY
            options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05,
                thenDragTo: options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: targetAbove ? 0.65 : 0.35)),
                withVelocity: 100, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(saved.label.contains("C1 Soft daylight"))
        XCTAssertFalse(saved.label.contains("Exported"))
        XCTAssertNotNil(saved.label.range(of: #"\d{2}/\d{2}/\d{2} \d{2}:\d{2}"#, options: .regularExpression))
        XCTAssertGreaterThan(saved.frame.height, app.buttons["version.raw"].frame.height, "The full saved label wraps")
        XCTAssertGreaterThanOrEqual(saved.frame.minY, options.frame.minY - 0.5)
        XCTAssertLessThanOrEqual(saved.frame.maxY, options.frame.maxY + 0.5)
        let label = saved.label
        let frames = XCTAttachment(string: "Saved row: \(saved.frame); menu viewport: \(options.frame)")
        frames.name = "Largest text saved version bounds"; frames.lifetime = .keepAlways; add(frames)
        shot(app, "Largest text versions menu with full saved label")
        tap(saved, in: app)
        XCTAssertEqual(app.buttons["workspace.versions"].value as? String, label)
        XCTAssertFalse(saved.exists)
        XCTAssertTrue(app.scrollViews["viewer.image"].exists)
    }
    func testPreviewDisconnectClearsRecipeAndAutomaticallyReconnectsAtLargestText() {
        let app = launch(["--fixture-preview-failure", "--fixture-accessibility"])
        app.cells["grid.source-0"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout: 5))
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(1, in: app)
        wait { app.buttons["recipe.control"].label == "No recipe selected" }
        XCTAssertTrue(app.scrollViews["viewer.image"].exists)
        XCTAssertGreaterThan(app.scrollViews["viewer.image"].frame.height, 40)
        XCTAssertEqual(app.buttons["workspace.versions"].value as? String, "Original camera JPEG")
        XCTAssertFalse(app.buttons["workspace.export"].exists)
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        tap(app.buttons["recipe.control"], in: app)
        XCTAssertTrue(app.buttons["recipe.none"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["recipe.none"].isSelected)
        XCTAssertTrue(app.buttons["recipe.none"].isEnabled)
        for slot in 1...6 { XCTAssertTrue(app.buttons["recipe.slot.\(slot)"].isEnabled) }
        XCTAssertFalse(app.buttons["recipe.slot.7"].isEnabled)
        XCTAssertTrue(app.buttons["recipe.refresh"].isEnabled)
        shot(app, "Automatic reconnect keeps recipe cleared at AX5")
        tap(app.buttons["recipe.none"], in: app)
        XCTAssertTrue(app.scrollViews["viewer.image"].isHittable)
        for id in ["viewer.zoomOut", "viewer.fit", "viewer.zoomIn"] { XCTAssertFalse(app.buttons[id].exists) }
        let grid = app.collectionViews["photoGrid"], side = app.cells["grid.source-0"].frame.width
        XCTAssertGreaterThan(grid.frame.height, side)
        XCTAssertLessThan(grid.frame.height, side * 2)
        let frame = app.scrollViews["viewer.image"].frame
        app.buttons["drawer.toggle"].tap(); wait { app.buttons["drawer.toggle"].value as? String == "Expanded" }
        XCTAssertFalse(app.buttons["viewer.zoomIn"].exists)
        app.buttons["drawer.toggle"].tap(); wait { app.buttons["drawer.toggle"].value as? String == "Collapsed" }
        XCTAssertEqual(app.scrollViews["viewer.image"].frame, frame)
    }
    func testPairedC3PreviewSingleExportAndTrackedVersion() {
        let app = launch()
        app.cells["grid.source-0"].tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].waitForExistence(timeout: 5))
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(3, in: app)
        wait { app.scrollViews["viewer.image"].exists && !app.descendants(matching: .any)["viewer.status"].exists }
        wait { app.buttons["workspace.export"].isEnabled }
        XCTAssertFalse(app.buttons["workspace.versions"].exists)
        shot(app, "C3 preview with floating export")
        app.buttons["workspace.export"].tap()
        wait { app.buttons["app.status"].label.contains("1 saved") }
        clearRecipe(in: app)
        let saved = version("version.saved.", in: app)
        XCTAssertTrue(saved.label.contains("C3 Mountain greens"))
        shot(app, "Saved version recipe title and compact date subtitle")
        saved.tap()
        XCTAssertTrue(app.scrollViews["viewer.image"].exists)
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.staticTexts["export.counts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["export.counts"].label.contains("1 saved"))
        XCTAssertEqual(app.staticTexts["export.status"].label, "Export saved")
        shot(app, "Single export tracked and saved")
    }
    func testMixedBatchKeepsFrozenC3WhileRecipeChangesAndClearsForManualVersion() {
        let app = launch(["--fixture-held-save", "--fixture-held-start"])
        wait { app.buttons["fixture.finishStart"].value as? String == "active" }
        app.buttons["fixture.finishStart"].tap()
        app.cells["grid.source-0"].tap(); wait { app.buttons["app.status"].label.contains("Camera ready") }
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(3, in: app)
        selectFirstRow(app)
        wait { app.staticTexts["workspace.count"].label == "3 selected" }
        app.buttons["workspace.export"].tap()
        wait { app.buttons["app.status"].label.contains("Saving to Photos") }
        XCTAssertEqual(app.buttons["fixture.finishSave"].value as? String, "Awake")
        recipe(2, in: app)
        XCTAssertTrue(app.buttons["recipe.control"].label.contains("C2"))
        XCTAssertFalse(app.buttons["workspace.versions"].exists)
        clearRecipe(in: app)
        version("version.cameraJPEG", in: app).tap()
        XCTAssertEqual(app.buttons["recipe.control"].label, "No recipe selected")
        XCTAssertEqual(app.staticTexts["workspace.count"].label, "3 selected")
        XCTAssertFalse(app.buttons["workspace.export"].exists)
        shot(app, "Frozen C3 batch after clearing recipe and viewing original")
        app.buttons["fixture.finishSave"].tap()
        wait { app.buttons["app.status"].label.contains("3 saved") }
        app.buttons["app.status"].tap()
        XCTAssertEqual(app.staticTexts["export.recipe"].label, "Mountain greens")
        XCTAssertTrue(app.staticTexts["export.counts"].label.contains("3 saved"))
        shot(app, "Mixed batch complete with frozen recipe")
    }
    func testLimitedDeniedAndUnknownSaveRemainActionable() {
        var app = launch(["--fixture-denied"])
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.buttons["Open Settings"].exists)
        shot(app, "Denied Photos access")
        app.terminate()
        app = launch(["--fixture-limited"])
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.buttons["app.managePhotos"].exists)
        shot(app, "Limited Photos access")
        app.terminate()
        app = launch(["--fixture-unknown-save"])
        app.cells["grid.source-0"].tap(); wait { app.buttons["app.status"].label.contains("Camera ready") }
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(3, in: app)
        wait { app.buttons["workspace.export"].isEnabled }
        app.buttons["workspace.export"].tap()
        wait { app.buttons["app.status"].label.contains("Save unconfirmed") }
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.staticTexts["export.counts"].label.contains("0 saved"))
        XCTAssertTrue(app.staticTexts["export.counts"].label.contains("1 unconfirmed"))
        XCTAssertTrue(app.buttons["export.reconcile"].exists)
        XCTAssertFalse(app.buttons["export.resume"].exists)
        app.buttons["export.reconcile"].tap()
        XCTAssertEqual(app.staticTexts["export.status"].label, "Save unconfirmed")
        shot(app, "Unknown Photos save retained")
    }
    func testInjectedScenePauseRequiresExplicitResumeAfterSaveClassification() { backgroundFlow(native: false) }
    func testNativeHomeBackgroundBoundary() throws {
        guard ProcessInfo.processInfo.environment["FUJI_STUDIO_NATIVE_LIFECYCLE"] == "1" else {
            throw XCTSkip("NOT VERIFIED: Duo Home did not reach XCUIApplication.runningBackground or deliver a background scene callback while a synthetic save was held. See task12-red-epoch-scene-boundary.xcresult. Enable FUJI_STUDIO_NATIVE_LIFECYCLE=1 on a validated lifecycle destination.")
        }
        backgroundFlow(native: true)
    }
    private func backgroundFlow(native: Bool) {
        let app = launch(["--fixture-held-save"] + (native ? [] : ["--fixture-scene-controls"]))
        app.cells["grid.source-0"].tap(); wait { app.buttons["app.status"].label.contains("Camera ready") }
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(3, in: app)
        selectFirstRow(app)
        wait { app.staticTexts["workspace.count"].label == "3 selected" }
        app.buttons["workspace.export"].tap()
        wait { app.buttons["app.status"].label.contains("Saving to Photos") }
        if native {
            XCUIDevice.shared.press(.home)
            let reachedBackground = app.wait(for: .runningBackground, timeout: 5)
            let boundary = XCTAttachment(string: "Reached background: \(reachedBackground), application state: \(app.state.rawValue), at \(Date.timeIntervalSinceReferenceDate)")
            boundary.name = "Public background boundary"; boundary.lifetime = .keepAlways; add(boundary)
            app.activate()
            shot(app, "Actual scene state after Home and activate")
            guard reachedBackground else { XCTFail("Home did not produce a background application state"); return }
        } else {
            app.buttons["fixture.background"].tap()
            app.buttons["fixture.foreground"].tap()
        }
        XCTAssertTrue(app.buttons["fixture.finishSave"].waitForExistence(timeout: 5))
        app.buttons["fixture.finishSave"].tap()
        wait { app.buttons["app.status"].label.contains("Export paused") }
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.staticTexts["export.counts"].label.contains("1 saved"))
        XCTAssertTrue(app.staticTexts["export.counts"].label.contains("2 remaining"))
        wait { app.buttons["export.resume"].isEnabled }
        shot(app, native ? "Paused after verified native background" : "Paused after injected scene callbacks")
        app.buttons["export.resume"].tap()
        wait { app.staticTexts["export.counts"].label.contains("3 saved") }
        XCTAssertEqual(app.staticTexts["export.status"].label, "Export saved")
    }
    func testAXPinchInspectionStaysSeparateFromEnabledRecipeVersionsAndExport() {
        let app = launch(["--fixture-accessibility", "--fixture-dark"])
        app.cells["grid.source-0"].tap(); wait { app.buttons["app.status"].label.contains("Camera ready") }
        wait { app.buttons["app.status"].label.contains("Camera ready") }
        recipe(1, in: app)
        wait { app.buttons["workspace.export"].isEnabled }
        let viewer = app.scrollViews["viewer.image"], grid = app.collectionViews["photoGrid"]
        XCTAssertTrue(viewer.waitForExistence(timeout: 5))
        func magnitude() -> Double { Double((viewer.value as? String ?? "").split(separator: ",").first ?? "") ?? -1 }
        func inspect(_ name: String) {
            let floating = ["recipe.control", "workspace.export"]
            for id in ["viewer.zoomOut", "viewer.fit", "viewer.zoomIn"] { XCTAssertFalse(app.buttons[id].exists) }
            for id in floating {
                XCTAssertTrue(app.buttons[id].exists)
                XCTAssertTrue(app.buttons[id].isEnabled)
            }
            XCTAssertFalse(app.buttons["workspace.versions"].exists)
            XCTAssertFalse(app.buttons["workspace.export"].frame.intersects(app.buttons["recipe.control"].frame))
            XCTAssertGreaterThanOrEqual(app.buttons["workspace.export"].frame.minY, viewer.frame.minY - 0.5)
            XCTAssertLessThanOrEqual(app.buttons["workspace.export"].frame.maxY, viewer.frame.maxY)
            let frames = XCTAttachment(string: floating.map { "\($0): \(app.buttons[$0].frame)" }.joined(separator: "\n") + "\nViewer: \(viewer.frame), Grid: \(grid.frame)")
            frames.name = name + " inspection frames"; frames.lifetime = .keepAlways; add(frames)
            viewer.pinch(withScale: 2.5, velocity: 1); wait { magnitude() > 1.5 }
            viewer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).doubleTap()
            wait { abs(magnitude() - 1) < 0.01 }
            XCTAssertTrue(app.buttons["recipe.control"].label.contains("C1"))
            XCTAssertFalse(app.buttons["app.status"].label.contains("saved"))
            XCTAssertTrue(app.buttons["workspace.export"].isEnabled)
            // Over letterboxing, XCTest's automatic hit-point lookup tries to
            // scroll the zoom view. Use the same screen taps as recipe selection
            // and verify the menus actually open and dismiss without an export.
            tap(app.buttons["recipe.control"], in: app)
            XCTAssertTrue(app.buttons["recipe.slot.1"].waitForExistence(timeout: 5))
            tap(app.buttons["app.status"], in: app)
            XCTAssertTrue(app.buttons["recipe.slot.1"].waitForNonExistence(timeout: 3))
            XCTAssertFalse(app.buttons["app.status"].label.contains("saved"))
            shot(app, name)
        }
        inspect("AX5 collapsed enabled export and pinch inspection")
        let frame = viewer.frame, side = app.cells["grid.source-0"].frame.width
        XCTAssertGreaterThan(grid.frame.height, side)
        XCTAssertLessThan(grid.frame.height, side * 2)
        app.buttons["workspace.select"].tap()
        XCTAssertEqual(app.cells["grid.source-0"].frame.width, side, accuracy: 0.5)
        app.buttons["drawer.toggle"].tap(); wait { app.buttons["drawer.toggle"].value as? String == "Expanded" }
        // The selectors remain above the expanded drawer; there is no zoom button row.
        for id in ["viewer.zoomOut", "viewer.fit", "viewer.zoomIn"] { XCTAssertFalse(app.buttons[id].exists) }
        shot(app, "AX5 expanded drawer intentionally covers inspection controls")
        app.buttons["drawer.toggle"].tap(); wait { app.buttons["drawer.toggle"].value as? String == "Collapsed" }
        XCTAssertEqual(viewer.frame, frame)
        XCTAssertEqual(app.cells["grid.source-0"].frame.width, side, accuracy: 0.5)
        XCTAssertGreaterThan(grid.frame.height, side)
        XCTAssertLessThan(grid.frame.height, side * 2)
        inspect("AX5 recollapsed pinch inspection remains operable without export")
        // Floating controls over letterboxing can report isHittable == false to XCTest.
        // Verify a real screen tap still exports the selected recipe after inspection.
        tap(app.buttons["workspace.export"], in: app)
        wait { app.buttons["app.status"].label.contains("1 saved") }
        XCTAssertFalse(app.buttons["workspace.versions"].exists)
    }

    func testAccessibleFloatingPhotoControlsRemainSeparateWithoutConnect() {
        let app = launch(["--fixture-accessibility", "--fixture-limited", "--fixture-dark"])
        app.cells["grid.source-0"].tap()
        assertFloatingPhotoControls(app)
        XCTAssertGreaterThanOrEqual(app.buttons["app.status"].frame.height, 44)
        XCTAssertFalse(app.buttons["app.connect"].exists)
        XCTAssertFalse(app.buttons["app.status"].frame.intersects(app.buttons["recipe.control"].frame))
        app.buttons["drawer.toggle"].tap()
        wait { app.buttons["drawer.toggle"].value as? String == "Expanded" }
        let bottom = max(app.buttons["recipe.control"].frame.maxY, app.buttons["workspace.versions"].frame.maxY)
        XCTAssertGreaterThanOrEqual(app.buttons["drawer.toggle"].frame.minY, bottom)
        shot(app, "AX5 dark measured app controls and expanded drawer")
        app.buttons["app.status"].tap()
        XCTAssertTrue(app.buttons["app.managePhotos"].waitForExistence(timeout: 5))
        shot(app, "AX5 scrollable status and limited-access management")
    }
}
