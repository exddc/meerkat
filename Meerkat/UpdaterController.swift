import AppKit
import Sparkle

@MainActor
final class UpdaterController {
    private var controller: SPUStandardUpdaterController?

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    func start(bundle: Bundle = .main) {
        guard controller == nil else { return }
        guard Self.hasUpdateConfiguration(in: bundle.infoDictionary) else { return }

        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
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
