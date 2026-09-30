import XCTest

final class MenuBarInteractionTests: XCTestCase {
    @MainActor
    func testCameraDeletionRequiresConfirmation() {
        let app = launchApp()
        defer { app.terminate() }

        let statusItem = app.menuBars.statusItems["Meerkat"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        let settings = app.buttons["settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()
        resetCameras(in: app, count: 1)

        let removeButtons = app.buttons.matching(
            NSPredicate(format: "identifier ENDSWITH '-remove'")
        )
        XCTAssertEqual(removeButtons.count, 1)
        removeButtons.firstMatch.click()

        let cancel = app.buttons["cancel-camera-removal"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))

        cancel.click()
        XCTAssertEqual(removeButtons.count, 1)
        removeButtons.firstMatch.click()

        let confirm = app.buttons["confirm-camera-removal"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(removeButtons.firstMatch.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testPanelOpensFromMenuBar() {
        let app = launchApp()
        defer { app.terminate() }

        let statusItem = app.menuBars.statusItems["Meerkat"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        let settings = app.buttons["settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Meerkat panel"
        attachment.lifetime = .keepAlways
        add(attachment)
        statusItem.click()
    }

    @MainActor
    func testPanelKeepsFixedSizeAcrossCameraCountsAndSettings() {
        let app = launchApp()
        defer { app.terminate() }

        let statusItem = app.menuBars.statusItems["Meerkat"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        let settings = app.buttons["settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let panel = app.dialogs.firstMatch
        let initialFrame = panel.frame
        XCTAssertEqual(initialFrame.width, 420, accuracy: 1)
        XCTAssertEqual(initialFrame.height, 484, accuracy: 1)

        for count in [0, 1, 2, 5] {
            settings.click()
            XCTAssertTrue(app.buttons["settings-back"].waitForExistence(timeout: 5))
            resetCameras(in: app, count: count)
            XCTAssertEqual(panel.frame, initialFrame)
            app.buttons["settings-back"].click()
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            XCTAssertEqual(panel.frame, initialFrame)

            let tiles = app.buttons.matching(
                NSPredicate(format: "identifier ENDSWITH '-tile'")
            )
            if count > 0 {
                XCTAssertTrue(tiles.element(boundBy: count - 1).waitForExistence(timeout: 5))
            }
            XCTAssertEqual(tiles.count, count)
        }
        addScreenshot(named: "Fixed Panel")
    }

    @MainActor
    func testCameraVisibilityControlsGrid() {
        let app = launchApp()
        defer { app.terminate() }

        let statusItem = app.menuBars.statusItems["Meerkat"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        let settings = app.buttons["settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()
        resetCameras(in: app, count: 2)

        let visibilityButtons = app.buttons.matching(
            NSPredicate(format: "identifier ENDSWITH '-visibility'")
        )
        XCTAssertEqual(visibilityButtons.count, 2)
        visibilityButtons.firstMatch.click()
        XCTAssertEqual(visibilityButtons.firstMatch.label, "Show camera")
        addScreenshot(named: "TW-407 Settings")

        app.buttons["settings-back"].click()
        let tiles = app.buttons.matching(
            NSPredicate(format: "identifier ENDSWITH '-tile'")
        )
        XCTAssertEqual(tiles.count, 1)
    }

    @MainActor
    func testSettingsContents() {
        let app = launchApp()
        defer { app.terminate() }

        let statusItem = app.menuBars.statusItems["Meerkat"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        let settings = app.buttons["settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()
        resetCameras(in: app, count: 0)
        XCTAssertTrue(app.staticTexts["settings-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.checkBoxes["settings-start-at-login"].exists)
        XCTAssertTrue(app.checkBoxes["settings-background-streaming"].exists)
        XCTAssertTrue(app.popUpButtons["settings-show-camera-labels"].exists)
        XCTAssertTrue(app.buttons["settings-check-for-updates"].exists)
        XCTAssertTrue(app.staticTexts["settings-version"].exists)
        addScreenshot(named: "TW-418 Settings")
    }

    @MainActor
    func testTileExpandsAndReturnsToGrid() {
        let app = launchApp()
        defer { app.terminate() }

        let statusItem = app.menuBars.statusItems["Meerkat"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        let settings = app.buttons["settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()

        resetCameras(in: app, count: 3)
        app.buttons["settings-back"].click()

        let tiles = app.buttons.matching(
            NSPredicate(format: "identifier ENDSWITH '-tile'")
        )
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(tiles.count, 2)
        addScreenshot(named: "TW-375 Before")

        tiles.firstMatch.click()
        waitForHittableTileCount(1, in: tiles)
        XCTAssertFalse(settings.isHittable)
        addScreenshot(named: "TW-375 Expanded")

        tiles.allElementsBoundByIndex.first(where: \.isHittable)?.click()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
    }

    @MainActor
    func testFullWidthTileDoesNotExpand() {
        let app = launchApp()
        defer { app.terminate() }

        let statusItem = app.menuBars.statusItems["Meerkat"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        let settings = app.buttons["settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()
        resetCameras(in: app, count: 2)
        app.buttons["settings-back"].click()

        let tiles = app.buttons.matching(
            NSPredicate(format: "identifier ENDSWITH '-tile'")
        )
        XCTAssertEqual(tiles.count, 2)
        tiles.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

        XCTAssertEqual(tiles.count, 2)
        XCTAssertTrue(settings.exists)
        addScreenshot(named: "TW-375 Full Width Guard")
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        return app
    }

    @MainActor
    private func resetCameras(in app: XCUIApplication, count: Int) {
        let removeButtons = app.buttons.matching(
            NSPredicate(format: "identifier ENDSWITH '-remove'")
        )
        while removeButtons.firstMatch.exists {
            removeButtons.firstMatch.click()
            let confirm = app.buttons["confirm-camera-removal"]
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.click()
        }

        let addCamera = app.buttons["settings-add-camera"]
        XCTAssertTrue(addCamera.waitForExistence(timeout: 5))
        for _ in 0..<count {
            addCamera.click()
        }
    }

    @MainActor
    private func waitForHittableTileCount(
        _ count: Int,
        in tiles: XCUIElementQuery
    ) {
        let predicate = NSPredicate { _, _ in
            MainActor.assumeIsolated {
                tiles.allElementsBoundByIndex.filter { $0.isHittable }.count == count
            }
        }
        expectation(for: predicate, evaluatedWith: tiles)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    private func addScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
