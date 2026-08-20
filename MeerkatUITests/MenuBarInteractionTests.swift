import XCTest

final class MenuBarInteractionTests: XCTestCase {
    @MainActor
    func testPanelOpensFromMenuBar() {
        let app = XCUIApplication()
        app.launch()

        let statusItem = app.menuBars.statusItems["Meerkat"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()

        for number in 1...4 {
            let video = app.descendants(matching: .any)["camera-\(number)-video"]
            XCTAssertTrue(video.waitForExistence(timeout: 5))

            let name = app.staticTexts["camera-\(number)-name"]
            XCTAssertTrue(name.waitForExistence(timeout: 2))
        }

        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Meerkat camera grid"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
