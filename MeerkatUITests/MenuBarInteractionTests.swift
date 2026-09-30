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
    func testPanelFitsCameraCountsAndResizesForSettings() {
        let app = launchApp()
        defer { app.terminate() }

        let statusItem = app.menuBars.statusItems["Meerkat"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        let settings = app.buttons["settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let panel = app.dialogs.firstMatch
        let sizes: [(Int, CGFloat)] = [
            (0, 239.75), (1, 239.75), (2, 475.5), (3, 241.5),
            (4, 241.5), (5, 360.25), (8, 479), (10, 484),
        ]
        for (count, height) in sizes {
            settings.click()
            XCTAssertTrue(app.buttons["settings-back"].waitForExistence(timeout: 5))
            waitForPanelHeight(484, in: panel)
            if count == 0 {
                resetCameras(in: app, count: 0)
            } else {
                let removeButtons = app.buttons.matching(
                    NSPredicate(format: "identifier ENDSWITH '-remove'")
                )
                for _ in removeButtons.count..<count {
                    app.buttons["settings-add-camera"].click()
                }
            }
            XCTAssertEqual(panel.frame.height, 484, accuracy: 1)
            app.buttons["settings-back"].click()
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            waitForPanelHeight(height, in: panel)
            XCTAssertEqual(panel.frame.width, 420, accuracy: 1)

            let tiles = app.buttons.matching(
                NSPredicate(format: "identifier ENDSWITH '-tile'")
            )
            if count > 0 {
                XCTAssertTrue(tiles.element(boundBy: count - 1).waitForExistence(timeout: 5))
            }
            XCTAssertEqual(tiles.count, count)
            if count > 0, count <= 8 {
                XCTAssertEqual(tiles.firstMatch.frame.minY - panel.frame.minY, 4, accuracy: 1)
                XCTAssertEqual(panel.frame.maxY - tiles.element(boundBy: count - 1).frame.maxY, 4, accuracy: 1)
            }
            let attachment = XCTAttachment(screenshot: panel.screenshot())
            attachment.name = "\(count) Cameras"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
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
        waitForPanelHeight(239.75, in: app.dialogs.firstMatch)
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
        waitForPanelHeight(241.5, in: app.dialogs.firstMatch)
        addScreenshot(named: "TW-375 Before")

        tiles.firstMatch.click()
        waitForHittableTileCount(1, in: tiles)
        waitForPanelHeight(239.75, in: app.dialogs.firstMatch)
        XCTAssertFalse(settings.isHittable)
        addScreenshot(named: "TW-375 Expanded")

        tiles.allElementsBoundByIndex.first(where: \.isHittable)?.click()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        waitForPanelHeight(241.5, in: app.dialogs.firstMatch)
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
    private func waitForPanelHeight(_ height: CGFloat, in panel: XCUIElement) {
        let predicate = NSPredicate { _, _ in
            MainActor.assumeIsolated {
                abs(panel.frame.height - height) <= 1
            }
        }
        expectation(for: predicate, evaluatedWith: panel)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(panel.frame.height, height, accuracy: 1)
    }

    @MainActor
    private func addScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
