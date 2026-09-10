import AppKit
import Combine
import Sparkle

@MainActor
final class UpdaterController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private var controller: SPUStandardUpdaterController?

    func start(bundle: Bundle = .main) {
        guard controller == nil else { return }
        guard Self.hasUpdateConfiguration(in: bundle.infoDictionary) else { return }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        controller.updater
            .publisher(for: \.canCheckForUpdates, options: [.initial, .new])
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        guard let controller else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            controller.checkForUpdates(nil)
        }
    }

    nonisolated static func hasUpdateConfiguration(in infoDictionary: [String: Any]?) -> Bool {
        guard let feedURL = infoDictionary?["SUFeedURL"] as? String,
              let publicKey = infoDictionary?["SUPublicEDKey"] as? String else {
            return false
        }
        return !feedURL.isEmpty
            && !publicKey.isEmpty
            && !publicKey.contains("$(")
    }
}
