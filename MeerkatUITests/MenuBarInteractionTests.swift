import XCTest

final class MenuBarInteractionTests: XCTestCase {
    @MainActor
    func testPanelOpensFromMenuBar() {
        let app = XCUIApplication()
        app.launch()
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
    func testTileExpandsAndReturnsToGrid() {
        let app = XCUIApplication()
        app.launch()
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
        let app = XCUIApplication()
        app.launch()
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
    func testSettingsTransitionKeepsSingleTileStable() {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        let statusItem = app.menuBars.statusItems["Meerkat"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        let settings = app.buttons["settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.click()
        resetCameras(in: app, count: 1)
        app.buttons["settings-back"].click()

        let tile = app.buttons.matching(
            NSPredicate(format: "identifier ENDSWITH '-tile'")
        ).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        let initialFrame = tile.frame

        settings.click()
        XCTAssertTrue(app.buttons["settings-back"].waitForExistence(timeout: 5))
        app.buttons["settings-back"].click()

        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertEqual(tile.frame, initialFrame)
        addScreenshot(named: "TW-400 After")
    }

    @MainActor
    private func resetCameras(in app: XCUIApplication, count: Int) {
        let removeButtons = app.buttons.matching(
            NSPredicate(format: "identifier ENDSWITH '-remove'")
        )
        while removeButtons.firstMatch.exists {
            removeButtons.firstMatch.click()
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
