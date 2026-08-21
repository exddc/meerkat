enum AppInfo {
    static let name = "Meerkat"
    static let menuBarIcon = "MenuBarIcon"
    static let cameraLabelVisibilityKey = "cameraLabelVisibility"
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
