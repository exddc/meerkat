import AppKit
import SwiftData
import SwiftUI

@MainActor
final class MeerkatApplicationDelegate: NSObject, NSApplicationDelegate {
    let ingestStore = CameraIngestStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSClassFromString("XCTestCase") == nil else { return }
        ingestStore.synchronize(Persistence.cameraIngestConfigurations())
    }

    func applicationWillTerminate(_ notification: Notification) {
        ingestStore.stopAll()
    }
}

@main
struct MeerkatApp: App {
    @NSApplicationDelegateAdaptor(MeerkatApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(ingestStore: appDelegate.ingestStore)
        } label: {
            Image(AppInfo.menuBarIcon)
                .renderingMode(.template)
                .accessibilityLabel(AppInfo.name)
        }
        .menuBarExtraStyle(.window)
        .modelContainer(Persistence.container)
    }
}
