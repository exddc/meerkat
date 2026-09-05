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
}
