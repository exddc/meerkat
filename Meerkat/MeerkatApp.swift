import SwiftData
import SwiftUI

@main
struct MeerkatApp: App {
    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
        } label: {
            Image(AppInfo.menuBarIcon)
                .renderingMode(.template)
                .accessibilityLabel(AppInfo.name)
        }
        .menuBarExtraStyle(.window)
        .modelContainer(Persistence.container)
    }
}
