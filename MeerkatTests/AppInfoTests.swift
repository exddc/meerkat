import AppKit
import Testing
@testable import Meerkat

struct AppInfoTests {
    @Test
    func menuBarIdentity() {
        #expect(AppInfo.name == "Meerkat")
        #expect(AppInfo.menuBarIcon == "MenuBarIcon")
        #expect(NSImage(named: AppInfo.menuBarIcon) != nil)
    }

    @Test
    func cameraLabelVisibility() {
        #expect(CameraLabelVisibility.always.isVisible(isHovering: false))
        #expect(CameraLabelVisibility.always.isVisible(isHovering: true))
        #expect(!CameraLabelVisibility.never.isVisible(isHovering: false))
        #expect(!CameraLabelVisibility.never.isVisible(isHovering: true))
        #expect(!CameraLabelVisibility.onHover.isVisible(isHovering: false))
        #expect(CameraLabelVisibility.onHover.isVisible(isHovering: true))
    }
}
