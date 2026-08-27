import AppKit
import SwiftData
import SwiftUI

struct MenuBarPanel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Camera.sortIndex) private var cameras: [Camera]
    @State private var isVisible = false
    @State private var showsSettings: Bool

    private let playbackEnabled: Bool
    private let panelWidth = CameraGridLayout.panelWidth
    private let panelMinHeight = CameraGridLayout.panelMinimumHeight
    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 4),
            count: CameraGridLayout.columnCount(for: cameras.count)
        )
    }

    private var gridPanelHeight: CGFloat {
        CameraGridLayout.panelHeight(for: cameras.count)
    }

    private var contentHeight: CGFloat {
        showsSettings ? CameraGridLayout.settingsPanelHeight : gridPanelHeight
    }

    init(
        playbackEnabled: Bool = true,
        showsSettings: Bool = false
    ) {
        self.playbackEnabled = playbackEnabled
        _showsSettings = State(initialValue: showsSettings)
    }

    var body: some View {
        HStack(spacing: 0) {
            cameraGrid
                .frame(width: panelWidth)

            SettingsSheet(onBack: { setShowsSettings(false) })
                .frame(width: panelWidth)
        }
        .offset(x: showsSettings ? -panelWidth : 0)
        .frame(width: panelWidth, height: contentHeight, alignment: .topLeading)
        .clipped()
        .background {
            PanelWindowObserver(contentSize: CGSize(width: panelWidth, height: contentHeight)) {
                isVisible = $0
            }
        }
        .onAppear {
            isVisible = true
        }
        .onDisappear {
            isVisible = false
        }
    }

    private var cameraGrid: some View {
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
        .frame(maxWidth: .infinity, minHeight: panelMinHeight, alignment: .top)
        .overlay {
            if cameras.isEmpty {
                VStack(spacing: 10) {
                    Image(AppInfo.menuBarIcon)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 36, height: 36)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)

                    VStack(spacing: 4) {
                        Text(AppInfo.name)
                            .font(.headline)

                        Text("Add a camera in Settings")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("empty-cameras")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                setShowsSettings(true)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            .padding(12)
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settings-button")
        }
    }

    private func setShowsSettings(_ value: Bool) {
        let animation: Animation? = reduceMotion
            ? nil
            : .spring(response: 0.42, dampingFraction: 0.80)
        withAnimation(animation) {
            showsSettings = value
        }
    }
}

private struct PanelWindowObserver: NSViewRepresentable {
    var contentSize: CGSize
    var onVisibilityChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ObserverView()
        view.onWindowChange = { [coordinator = context.coordinator] window in
            coordinator.observe(window)
        }
        context.coordinator.update(contentSize: contentSize, onVisibilityChange: onVisibilityChange)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(contentSize: contentSize, onVisibilityChange: onVisibilityChange)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(contentSize: contentSize, onVisibilityChange: onVisibilityChange)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.observe(nil)
    }

    @MainActor
    final class Coordinator {
        var onVisibilityChange: (Bool) -> Void
        private var contentSize: CGSize
        private var observations: [NSObjectProtocol] = []
        private weak var window: NSWindow?
        private var lastVisible: Bool?

        init(contentSize: CGSize, onVisibilityChange: @escaping (Bool) -> Void) {
            self.contentSize = contentSize
            self.onVisibilityChange = onVisibilityChange
        }

        func update(contentSize: CGSize, onVisibilityChange: @escaping (Bool) -> Void) {
            self.contentSize = contentSize
            self.onVisibilityChange = onVisibilityChange
            resizeWindow()
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

            resizeWindow()

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

        private func resizeWindow() {
            guard let window, window.contentView?.bounds.size != contentSize else { return }
            window.setContentSize(contentSize)
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

#Preview("Empty Light") {
    MenuBarPanel(playbackEnabled: false)
        .modelContainer(Persistence.preview(cameras: []))
        .preferredColorScheme(.light)
}

#Preview("Empty Dark") {
    MenuBarPanel(playbackEnabled: false)
        .modelContainer(Persistence.preview(cameras: []))
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    MenuBarPanel(playbackEnabled: false)
        .modelContainer(Persistence.preview())
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    MenuBarPanel(playbackEnabled: false)
        .modelContainer(Persistence.preview())
        .preferredColorScheme(.dark)
}

#Preview("Two Cameras") {
    MenuBarPanel(playbackEnabled: false)
        .modelContainer(Persistence.preview(cameras: [
            ("Camera 1", "https://camera.test/1"),
            ("Camera 2", "https://camera.test/2"),
        ]))
}

#Preview("Five Cameras") {
    MenuBarPanel(playbackEnabled: false)
        .modelContainer(Persistence.preview(cameras: [
            ("Camera 1", "https://camera.test/1"),
            ("Camera 2", "https://camera.test/2"),
            ("Camera 3", "https://camera.test/3"),
            ("Camera 4", "https://camera.test/4"),
            ("Camera 5", "https://camera.test/5"),
        ]))
}

#Preview("Settings Open Light") {
    MenuBarPanel(playbackEnabled: false, showsSettings: true)
        .modelContainer(Persistence.preview(cameras: []))
        .preferredColorScheme(.light)
}

#Preview("Settings Open Dark") {
    MenuBarPanel(playbackEnabled: false, showsSettings: true)
        .modelContainer(Persistence.preview(cameras: []))
        .preferredColorScheme(.dark)
}
