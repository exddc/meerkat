import SwiftUI

@main
struct MeerkatApp: App {
    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
        } label: {
            Image(systemName: AppInfo.menuBarSymbol)
                .accessibilityLabel(AppInfo.name)
        }
        .menuBarExtraStyle(.window)
    }
}
