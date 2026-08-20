import AppKit
import SwiftUI

struct MenuBarPanel: View {
    @State private var isVisible = false

    private let cameras: [Camera]
    private let playbackEnabled: Bool
    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4),
    ]

    init(
        cameras: [Camera] = CameraCatalog.bundled,
        playbackEnabled: Bool = true
    ) {
        self.cameras = cameras
        self.playbackEnabled = playbackEnabled
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(cameras) { camera in
                VideoTile(
                    camera: camera,
                    isActive: isVisible,
                    playbackEnabled: playbackEnabled
                )
            }
        }
        .padding(4)
        .frame(width: 420)
        .background {
            PanelWindowObserver { isVisible = $0 }
        }
        .onAppear {
            isVisible = true
        }
        .onDisappear {
            isVisible = false
        }
    }
}

private struct PanelWindowObserver: NSViewRepresentable {
    var onVisibilityChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ObserverView()
        view.onWindowChange = { [coordinator = context.coordinator] window in
            coordinator.observe(window)
        }
        context.coordinator.onVisibilityChange = onVisibilityChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onVisibilityChange = onVisibilityChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onVisibilityChange: onVisibilityChange)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.observe(nil)
    }

    @MainActor
    final class Coordinator {
        var onVisibilityChange: (Bool) -> Void
        private var observations: [NSObjectProtocol] = []
        private weak var window: NSWindow?
        private var lastVisible: Bool?

        init(onVisibilityChange: @escaping (Bool) -> Void) {
            self.onVisibilityChange = onVisibilityChange
        }

        func observe(_ window: NSWindow?) {
            guard window !== self.window else { return }

            observations.forEach(NotificationCenter.default.removeObserver)
            observations = []
            self.window = window

            guard let window else {
                publish(false)
                return
            }

            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didChangeOcclusionStateNotification,
            ]
            observations = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.publishVisibility()
                    }
                }
            }
            publishVisibility()
        }

        private func publishVisibility() {
            guard let window else {
                publish(false)
                return
            }

            publish(window.isVisible && window.occlusionState.contains(.visible))
        }

        private func publish(_ visible: Bool) {
            guard lastVisible != visible else { return }
            lastVisible = visible
            onVisibilityChange(visible)
        }
    }

    private final class ObserverView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}

#Preview("Light") {
    MenuBarPanel(playbackEnabled: false)
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    MenuBarPanel(playbackEnabled: false)
        .preferredColorScheme(.dark)
}
