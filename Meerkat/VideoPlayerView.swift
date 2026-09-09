import AppKit
import AVFoundation
import SwiftUI

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
    let ingest: HTTPFLVIngest?
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
        context.coordinator.update(ingest: ingest, active: isActive,
                                   view: view, onStateChange: onStateChange)
    }

    static func dismantleNSView(_ view: SampleBufferVideoView, coordinator: Coordinator) {
        coordinator.stop(view: view)
    }

    @MainActor
    final class Coordinator {
        private var ingest: HTTPFLVIngest?
        private var generation = UUID()
        private var onStateChange: ((PlaybackState) -> Void)?

        func update(ingest: HTTPFLVIngest?, active: Bool, view: SampleBufferVideoView,
                    onStateChange: @escaping (PlaybackState) -> Void) {
            self.onStateChange = onStateChange
            guard active else { stop(view: view); return }
            guard let ingest else {
                stop(view: view)
                schedule(.connecting)
                return
            }
            guard self.ingest !== ingest else { return }
            stop(view: view)
            self.ingest = ingest
            schedule(.connecting)
            do {
                try ingest.attachDisplay(view.prepareLayer()) { [weak self] state in
                    self?.schedule(state)
                }
            } catch {
                schedule(.reconnecting)
            }
        }

        func stop(view: SampleBufferVideoView) {
            generation = UUID()
            ingest?.detachDisplay()
            ingest = nil
            view.removeDisplayLayer()
        }

        private func schedule(_ state: PlaybackState) {
            let generation = self.generation
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.onStateChange?(state)
            }
        }
    }
}
