import AppKit
import Testing
@testable import Meerkat

struct AppInfoTests {
    @Test
    func menuBarIdentity() {
        #expect(AppInfo.name == "Meerkat")
        #expect(AppInfo.menuBarIcon == "MenuBarIcon")
        #expect(AppInfo.version == "0.0.1")
        #expect(NSImage(named: AppInfo.menuBarIcon) != nil)
    }

    @Test
    func updateConfigurationRequiresFeedAndPublicKey() {
        #expect(!UpdaterController.hasUpdateConfiguration(in: nil))
        #expect(!UpdaterController.hasUpdateConfiguration(in: [
            "SUFeedURL": "https://exddc.github.io/meerkat/appcast.xml"
        ]))
        #expect(!UpdaterController.hasUpdateConfiguration(in: [
            "SUFeedURL": "https://exddc.github.io/meerkat/appcast.xml",
            "SUPublicEDKey": "$(SPARKLE_PUBLIC_KEY)"
        ]))
        #expect(UpdaterController.hasUpdateConfiguration(in: [
            "SUFeedURL": "https://exddc.github.io/meerkat/appcast.xml",
            "SUPublicEDKey": "public-key"
        ]))
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
