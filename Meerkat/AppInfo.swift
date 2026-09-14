import Foundation

enum AppInfo {
    static let name = "Meerkat"
    static let menuBarIcon = "MenuBarIcon"
    static let cameraLabelVisibilityKey = "cameraLabelVisibility"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Unknown"
    }
}

enum BackgroundStreaming {
    static let enabledKey = "backgroundStreamingEnabled"
    static let defaultEnabled = true

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }

    static func shouldStream(isPanelVisible: Bool, isEnabled: Bool) -> Bool {
        isPanelVisible || isEnabled
    }
}

enum CameraLabelVisibility: String, CaseIterable {
    case always
    case never
    case onHover

    var title: String {
        switch self {
        case .always: "Always"
        case .never: "Never"
        case .onHover: "On hover"
        }
    }

    func isVisible(isHovering: Bool) -> Bool {
        switch self {
        case .always: true
        case .never: false
        case .onHover: isHovering
        }
    }
}
