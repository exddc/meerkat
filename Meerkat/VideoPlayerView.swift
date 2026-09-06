import AppKit
import AVFoundation
import SwiftUI

enum PlaybackState: Equatable {
    case connecting
    case reconnecting
    case playing

    var status: (symbol: String, text: String)? {
        switch self {
        case .connecting:
            ("antenna.radiowaves.left.and.right", "Connecting…")
        case .reconnecting:
            ("arrow.clockwise", "Reconnecting…")
        case .playing:
            nil
        }
    }
}

final class SampleBufferVideoView: NSView {
    private(set) var displayLayer: AVSampleBufferDisplayLayer?

    func prepareLayer() -> AVSampleBufferDisplayLayer {
        if let displayLayer { return displayLayer }
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let display = AVSampleBufferDisplayLayer()
        display.videoGravity = .resizeAspect
        display.frame = bounds
        layer?.addSublayer(display)
        displayLayer = display
        return display
    }

    func removeDisplayLayer() {
        displayLayer?.sampleBufferRenderer.flush(removingDisplayedImage: true)
        displayLayer?.removeFromSuperlayer()
        displayLayer = nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer?.frame = bounds
        CATransaction.commit()
    }
}

struct VideoPlayerView: NSViewRepresentable {
    let camera: Camera
    let streamURLString: String
    let isActive: Bool
    let onStateChange: @MainActor (PlaybackState) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SampleBufferVideoView {
        SampleBufferVideoView(frame: NSRect(x: 0, y: 0, width: 16, height: 9))
    }

    func updateNSView(_ view: SampleBufferVideoView, context: Context) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("\(camera.name) video")
        view.setAccessibilityIdentifier("\(camera.cameraID.uuidString)-video")
        context.coordinator.update(url: camera.playableStreamURL, active: isActive,
                                   view: view, onStateChange: onStateChange)
    }

    static func dismantleNSView(_ view: SampleBufferVideoView, coordinator: Coordinator) {
        coordinator.stop(view: view)
    }

    @MainActor
    final class Coordinator {
        private var player: HTTPFLVPlayer?
        private var url: URL?
        private var generation = UUID()
        private var onStateChange: ((PlaybackState) -> Void)?

        func update(url: URL?, active: Bool, view: SampleBufferVideoView,
                    onStateChange: @escaping (PlaybackState) -> Void) {
            self.onStateChange = onStateChange
            guard active else { stop(view: view); return }
            guard let url else {
                stop(view: view)
                let generation = self.generation
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.onStateChange?(.connecting)
                }
                return
            }
            guard player == nil || self.url != url else { return }
            stop(view: view)
            self.url = url
            let generation = self.generation
            let report: (PlaybackState) -> Void = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.onStateChange?(state)
                }
            }
            report(.connecting)
            do {
                player = try HTTPFLVPlayer(url: url, displayLayer: view.prepareLayer(),
                                           onStateChange: report)
                player?.start()
            } catch {
                report(.reconnecting)
            }
        }

        func stop(view: SampleBufferVideoView) {
            generation = UUID()
            player?.stop()
            player = nil
            url = nil
            view.removeDisplayLayer()
        }
    }
}
