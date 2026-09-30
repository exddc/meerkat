import AppKit
import SwiftData
import SwiftUI

struct MenuBarPanel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Camera.sortIndex) private var cameras: [Camera]
    @AppStorage(BackgroundStreaming.enabledKey) private var backgroundStreamingEnabled = BackgroundStreaming.defaultEnabled
    @State private var expandedCameraID: UUID?
    @State private var isVisible = false
    @State private var showsSettings: Bool
    @ObservedObject private var ingestStore: CameraIngestStore
    @ObservedObject private var updater: UpdaterController

    private let playbackEnabled: Bool
    private var visibleCameras: [Camera] {
        cameras.filter { $0.isVisible && $0.requiresAddressChange != true }
    }

    init(
        ingestStore: CameraIngestStore,
        updater: UpdaterController = UpdaterController(),
        playbackEnabled: Bool = true,
        showsSettings: Bool = false
    ) {
        self.ingestStore = ingestStore
        _updater = ObservedObject(wrappedValue: updater)
        self.playbackEnabled = playbackEnabled
        _showsSettings = State(initialValue: showsSettings)
    }

    private var ingestConfigurations: [CameraIngestConfiguration] {
        visibleCameras.map(CameraIngestConfiguration.init)
    }

    private var cameraGridHeight: CGFloat {
        CameraGridLayout.panelHeight(
            for: visibleCameras.count,
            isExpanded: expandedCameraID != nil
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            cameraGrid
                .frame(width: CameraGridLayout.panelWidth, height: cameraGridHeight)

            SettingsSheet(
                onBack: { setShowsSettings(false) },
                canCheckForUpdates: updater.canCheckForUpdates,
                onCheckForUpdates: updater.checkForUpdates
            )
                .frame(width: CameraGridLayout.panelWidth, height: CameraGridLayout.settingsHeight)
        }
        .offset(x: showsSettings ? -CameraGridLayout.panelWidth : 0)
        .frame(
            width: CameraGridLayout.panelWidth,
            height: showsSettings ? CameraGridLayout.settingsHeight : cameraGridHeight,
            alignment: .topLeading
        )
        .clipped()
        .background {
            PanelVisibilityObserver(onVisibilityChange: setPanelVisibility)
        }
        .onAppear {
            setPanelVisibility(true)
        }
        .onChange(of: ingestConfigurations) {
            if let expandedCameraID,
               !visibleCameras.contains(where: { $0.cameraID == expandedCameraID })
                || !CameraGridLayout.canExpandTiles(for: visibleCameras.count) {
                self.expandedCameraID = nil
            }
            synchronizeIngests()
        }
        .onChange(of: backgroundStreamingEnabled) {
            synchronizeIngests()
        }
        .onDisappear {
            setPanelVisibility(false)
        }
    }

    private var cameraGrid: some View {
        GeometryReader { proxy in
            ScrollView {
                CameraTileLayout(
                    expandedCameraID: expandedCameraID,
                    viewportSize: proxy.size
                ) {
                    ForEach(visibleCameras) { camera in
                        interactiveTile(camera)
                        .layoutValue(key: CameraTileIDKey.self, value: camera.cameraID)
                        .opacity(
                            expandedCameraID == nil || expandedCameraID == camera.cameraID
                                ? 1
                                : 0
                        )
                        .allowsHitTesting(
                            expandedCameraID == nil || expandedCameraID == camera.cameraID
                        )
                        .accessibilityHidden(
                            expandedCameraID != nil && expandedCameraID != camera.cameraID
                        )
                        .zIndex(expandedCameraID == camera.cameraID ? 1 : 0)
                    }
                }
            }
            .scrollDisabled(expandedCameraID != nil)
            .scrollIndicators(expandedCameraID == nil ? .automatic : .hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            if visibleCameras.isEmpty {
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

                        Text(emptyCameraMessage)
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
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .padding(8)
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settings-button")
            .opacity(expandedCameraID == nil ? 1 : 0)
            .allowsHitTesting(expandedCameraID == nil)
            .accessibilityHidden(expandedCameraID != nil)
        }
    }

    private var emptyCameraMessage: String {
        if cameras.isEmpty { return "Add a camera in Settings" }
        if cameras.contains(where: { $0.requiresAddressChange == true }) {
            return "Finish setting up a camera in Settings"
        }
        return "Show a camera in Settings"
    }

    private func interactiveTile(_ camera: Camera) -> some View {
        Button {
            setExpandedCamera(camera)
        } label: {
            VideoTile(
                camera: camera,
                ingest: ingestStore.ingest(for: camera.cameraID),
                isActive: isVisible
                    && !showsSettings
                    && (expandedCameraID == nil || expandedCameraID == camera.cameraID),
                playbackEnabled: playbackEnabled
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(
            expandedCameraID != nil
                || CameraGridLayout.canExpandTiles(for: visibleCameras.count)
        )
        .accessibilityLabel(camera.name)
        .accessibilityHint(
            expandedCameraID == camera.cameraID
                ? "Show all cameras"
                : CameraGridLayout.canExpandTiles(for: visibleCameras.count)
                    ? "Expand camera"
                    : ""
        )
        .accessibilityIdentifier("\(camera.cameraID.uuidString)-tile")
    }

    private func synchronizeIngests(isPanelVisible: Bool? = nil) {
        let shouldStream = playbackEnabled && BackgroundStreaming.shouldStream(
            isPanelVisible: isPanelVisible ?? isVisible,
            isEnabled: backgroundStreamingEnabled
        )
        ingestStore.synchronize(shouldStream ? ingestConfigurations : [])
    }

    private func setPanelVisibility(_ isVisible: Bool) {
        self.isVisible = isVisible
        synchronizeIngests(isPanelVisible: isVisible)
    }

    private func setExpandedCamera(_ camera: Camera) {
        guard expandedCameraID == camera.cameraID
                || CameraGridLayout.canExpandTiles(for: visibleCameras.count) else {
            return
        }
        let animation: Animation? = reduceMotion ? nil : .smooth(duration: 0.3)
        withAnimation(animation) {
            expandedCameraID = expandedCameraID == camera.cameraID
                ? nil
                : camera.cameraID
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

private struct PanelVisibilityObserver: NSViewRepresentable {
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

#Preview("Empty Light") {
    MenuBarPanel(ingestStore: CameraIngestStore(), playbackEnabled: false)
        .modelContainer(Persistence.preview(cameras: []))
        .preferredColorScheme(.light)
}

#Preview("Empty Dark") {
    MenuBarPanel(ingestStore: CameraIngestStore(), playbackEnabled: false)
        .modelContainer(Persistence.preview(cameras: []))
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    MenuBarPanel(ingestStore: CameraIngestStore(), playbackEnabled: false)
        .modelContainer(Persistence.preview())
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    MenuBarPanel(ingestStore: CameraIngestStore(), playbackEnabled: false)
        .modelContainer(Persistence.preview())
        .preferredColorScheme(.dark)
}

#Preview("Two Cameras") {
    MenuBarPanel(ingestStore: CameraIngestStore(), playbackEnabled: false)
        .modelContainer(Persistence.preview(cameras: [
            ("Camera 1", "https://camera.test/1"),
            ("Camera 2", "https://camera.test/2"),
        ]))
}

#Preview("Five Cameras") {
    MenuBarPanel(ingestStore: CameraIngestStore(), playbackEnabled: false)
        .modelContainer(Persistence.preview(cameras: [
            ("Camera 1", "https://camera.test/1"),
            ("Camera 2", "https://camera.test/2"),
            ("Camera 3", "https://camera.test/3"),
            ("Camera 4", "https://camera.test/4"),
            ("Camera 5", "https://camera.test/5"),
        ]))
}

#Preview("Settings Open Light") {
    MenuBarPanel(
        ingestStore: CameraIngestStore(),
        playbackEnabled: false,
        showsSettings: true
    )
        .modelContainer(Persistence.preview(cameras: []))
        .preferredColorScheme(.light)
}

#Preview("Settings Open Dark") {
    MenuBarPanel(
        ingestStore: CameraIngestStore(),
        playbackEnabled: false,
        showsSettings: true
    )
        .modelContainer(Persistence.preview(cameras: []))
        .preferredColorScheme(.dark)
}
