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
    func testSmallPanelShowsCameraColumn() {
        let app = launchApp(panelSize: "small")
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
        XCTAssertEqual(tiles.count, 3)

        let tileFrames = tiles.allElementsBoundByIndex.map(\.frame)
        XCTAssertEqual(tileFrames[0].minX, tileFrames[1].minX, accuracy: 1)
        XCTAssertEqual(tileFrames[1].minX, tileFrames[2].minX, accuracy: 1)
        addScreenshot(named: "TW-373 Small Panel")
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
        XCTAssertTrue(app.staticTexts["settings-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.checkBoxes["settings-start-at-login"].exists)
        XCTAssertTrue(app.checkBoxes["settings-background-streaming"].exists)
        let windowSize = app.popUpButtons["settings-window-size"]
        XCTAssertTrue(windowSize.exists)
        windowSize.click()
        for size in ["Small", "Medium", "Large"] {
            XCTAssertTrue(app.menuItems[size].waitForExistence(timeout: 5))
        }
        app.menuItems["Medium"].click()
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
    private func launchApp(panelSize: String = "medium") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-menuBarPanelSize", panelSize]
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
