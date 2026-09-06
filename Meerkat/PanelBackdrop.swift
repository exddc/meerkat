import AppKit
import SwiftUI

/// Dual-layer panel backdrop, adapted from OpenUsage's `PopoverBackdropView`.
///
/// `.opaque` is a solid `NSBox` in `textBackgroundColor` so the data region never
/// shows the desktop. Transparency reveals a behind-window `NSVisualEffectView`
/// that samples the desktop with vibrancy — the HIG-correct way to show the
/// wallpaper. SwiftUI materials only sample in-app content, so they cannot do this.
///
/// The slider crossfades the two layers: the vibrancy stays fully on whenever
/// there is any transparency, and the opaque tray's alpha is `1 - transparency`.
/// Window alpha stays 1 so text and camera tiles do not dim.
struct PanelBackdrop: NSViewRepresentable {
    var transparency: Double
    var appearance: NSAppearance?

    func makeNSView(context: Context) -> BackdropView {
        let view = BackdropView()
        view.onWindowChange = { [coordinator = context.coordinator] window in
            coordinator.observe(window)
        }
        context.coordinator.update(transparency: transparency, appearance: appearance)
        return view
    }

    func updateNSView(_ nsView: BackdropView, context: Context) {
        context.coordinator.update(transparency: transparency, appearance: appearance)
        nsView.setTransparency(transparency)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(transparency: transparency, appearance: appearance)
    }

    static func dismantleNSView(_ nsView: BackdropView, coordinator: Coordinator) {
        coordinator.observe(nil)
    }

    @MainActor
    final class Coordinator {
        private var transparency: Double
        private var appearance: NSAppearance?
        private weak var window: NSWindow?
        private var observations: [NSObjectProtocol] = []

        init(transparency: Double, appearance: NSAppearance?) {
            self.transparency = transparency
            self.appearance = appearance
        }

        func update(transparency: Double, appearance: NSAppearance?) {
            self.transparency = transparency
            self.appearance = appearance
            apply(to: window)
        }

        func observe(_ window: NSWindow?) {
            guard window !== self.window else {
                apply(to: window)
                return
            }

            observations.forEach(NotificationCenter.default.removeObserver)
            observations = []
            self.window = window

            guard let window else { return }

            apply(to: window)
            observations = [
                NotificationCenter.default.addObserver(
                    forName: AppearanceSetting.didChangeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.apply(to: self.window)
                    }
                },
            ]
        }

        private func apply(to window: NSWindow?) {
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.appearance = appearance ?? AppearanceSetting.current.nsAppearance
        }
    }

    final class BackdropView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        private let opaqueBox = NSBox()
        private let vibrancy = NSVisualEffectView()
        private var currentTransparency: Double = -1

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            translatesAutoresizingMaskIntoConstraints = false

            opaqueBox.boxType = .custom
            opaqueBox.titlePosition = .noTitle
            opaqueBox.borderWidth = 0
            opaqueBox.cornerRadius = 0
            opaqueBox.contentViewMargins = .zero
            opaqueBox.fillColor = .textBackgroundColor
            opaqueBox.wantsLayer = true
            opaqueBox.translatesAutoresizingMaskIntoConstraints = false

            vibrancy.material = .popover
            vibrancy.blendingMode = .behindWindow
            vibrancy.state = .active
            vibrancy.wantsLayer = true
            vibrancy.alphaValue = 0
            vibrancy.translatesAutoresizingMaskIntoConstraints = false

            addSubview(vibrancy)
            addSubview(opaqueBox, positioned: .above, relativeTo: vibrancy)
            NSLayoutConstraint.activate([
                vibrancy.leadingAnchor.constraint(equalTo: leadingAnchor),
                vibrancy.trailingAnchor.constraint(equalTo: trailingAnchor),
                vibrancy.topAnchor.constraint(equalTo: topAnchor),
                vibrancy.bottomAnchor.constraint(equalTo: bottomAnchor),
                opaqueBox.leadingAnchor.constraint(equalTo: leadingAnchor),
                opaqueBox.trailingAnchor.constraint(equalTo: trailingAnchor),
                opaqueBox.topAnchor.constraint(equalTo: topAnchor),
                opaqueBox.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }

        func setTransparency(_ value: Double) {
            let transparency = PanelTransparency.clamped(value)
            guard transparency != currentTransparency else { return }
            currentTransparency = transparency
            opaqueBox.alphaValue = 1 - transparency
            vibrancy.alphaValue = transparency > 0 ? 1 : 0
        }
    }
}
