import ServiceManagement

enum LaunchAtLoginStatus {
    case disabled
    case enabled
    case requiresApproval

    var isEnabled: Bool {
        self != .disabled
    }
}

@MainActor
protocol LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() async throws
    func openSystemSettings()
}

struct SystemLaunchAtLoginService: LaunchAtLoginServicing {
    private let service = SMAppService.mainApp

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        default:
            .disabled
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() async throws {
        try await service.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var requiresApproval: Bool
    @Published private(set) var isUpdating = false
    @Published var errorMessage: String?

    private let service: any LaunchAtLoginServicing

    init(service: any LaunchAtLoginServicing = SystemLaunchAtLoginService()) {
        self.service = service
        isEnabled = service.status.isEnabled
        requiresApproval = service.status == .requiresApproval
    }

    func refresh() {
        let status = service.status
        isEnabled = status.isEnabled
        requiresApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        guard !isUpdating, enabled != isEnabled else { return }
        isEnabled = enabled
        isUpdating = true

        Task {
            defer {
                refresh()
                isUpdating = false
            }

            do {
                if enabled {
                    try service.register()
                } else {
                    try await service.unregister()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
