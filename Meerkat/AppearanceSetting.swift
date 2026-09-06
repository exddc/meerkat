import AppKit
import SwiftUI

/// Explicit appearance override for the panel. `.system` follows macOS.
///
/// Applied as `NSApp.appearance` and pinned on the menu-bar window. `MenuBarExtra`
/// ignores SwiftUI's `preferredColorScheme`, matching OpenUsage's finding that the
/// override has to happen at the AppKit level. The menu-bar label is unaffected
/// (template image).
enum AppearanceSetting: String, CaseIterable {
    case system
    case light
    case dark

    static let key = "appearance"
    static let fallback = AppearanceSetting.system
    static let didChangeNotification = Notification.Name("AppearanceSettingDidChange")

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// `nil` for `.system` so the panel inherits live OS theme switches.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static var current: AppearanceSetting {
        resolved(from: UserDefaults.standard.string(forKey: key))
    }

    static func resolved(from rawValue: String?) -> AppearanceSetting {
        rawValue.flatMap(AppearanceSetting.init(rawValue:)) ?? fallback
    }

    @MainActor
    static func applyCurrent() {
        NSApplication.shared.appearance = current.nsAppearance
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
