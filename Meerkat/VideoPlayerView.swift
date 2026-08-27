import AppKit
import SwiftUI
import VLCKitSPM

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

struct VideoPlayerView: NSViewRepresentable {
    let camera: Camera
    let streamURLString: String
    let isActive: Bool
    let onStateChange: @MainActor (PlaybackState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(cameraID: camera.cameraID, onStateChange: onStateChange)
    }

    func makeNSView(context: Context) -> VLCVideoView {
        let videoView = VLCVideoView(frame: NSRect(x: 0, y: 0, width: 16, height: 9))
        videoView.wantsLayer = true
        videoView.layer?.backgroundColor = NSColor.black.cgColor
        videoView.layer?.cornerRadius = 12
        videoView.layer?.masksToBounds = true
        configureAccessibility(for: videoView)
        return videoView
    }

    func updateNSView(_ videoView: VLCVideoView, context: Context) {
        configureAccessibility(for: videoView)
        context.coordinator.onStateChange = onStateChange
        context.coordinator.update(camera: camera, isActive: isActive, in: videoView)
    }

    static func dismantleNSView(_ videoView: VLCVideoView, coordinator: Coordinator) {
        coordinator.stop()
    }

    private func configureAccessibility(for videoView: VLCVideoView) {
        videoView.setAccessibilityElement(true)
        videoView.setAccessibilityRole(.group)
        videoView.setAccessibilityLabel("\(camera.name) video")
        videoView.setAccessibilityIdentifier("\(camera.cameraID.uuidString)-video")
    }

    @MainActor
    final class Coordinator: NSObject, VLCMediaPlayerDelegate {
        var onStateChange: @MainActor (PlaybackState) -> Void

        private let player: VLCMediaPlayer
        private let cameraID: String
        private var endpoint = ""
        private var streamURLString = ""
        private var isActive = false
        private var hasPlayed = false
        private var lastReportedState = PlaybackState.connecting
        private var lastProgressLog = Date.distantPast
        private var lastStateLog: (name: String, hasVideoOut: Bool)?
        private var reconnectTask: Task<Void, Never>?

        init(
            cameraID: UUID,
            onStateChange: @escaping @MainActor (PlaybackState) -> Void
        ) {
            player = VLCMediaPlayer(library: CameraCertificateTrust.shared.library)
            self.cameraID = cameraID.uuidString
            self.onStateChange = onStateChange
            super.init()
            player.delegate = self
        }

        func update(camera: Camera, isActive active: Bool, in videoView: VLCVideoView) {
            if camera.streamURLString != streamURLString {
                let shouldPlay = active
                if isActive {
                    stop()
                }

                streamURLString = camera.streamURLString
                endpoint = camera.logEndpoint
                replaceMedia(with: camera)

                if shouldPlay {
                    start(in: videoView)
                }
                return
            }

            setActive(active, in: videoView)
        }

        func setActive(_ active: Bool, in videoView: VLCVideoView) {
            guard active != isActive else { return }

            if active {
                start(in: videoView)
            } else {
                stop()
            }
        }

        private func replaceMedia(with camera: Camera) {
            hasPlayed = false
            lastStateLog = nil

            guard let url = camera.playableStreamURL else {
                player.media = nil
                debugLog("waiting for stream URL")
                return
            }

            CameraCertificateTrust.shared.register(camera)
            let media = VLCMedia(url: url)
            media.addOption(":no-audio")
            media.addOption(":network-caching=300")
            if url.path == "/flv" {
                media.addOption(":http-continuous")
            }
            player.media = media
            debugLog("media endpoint=\(endpoint)")
        }

        private func start(in videoView: VLCVideoView) {
            isActive = true
            lastReportedState = .connecting
            onStateChange(.connecting)
            debugLog("start")

            guard player.media != nil else {
                debugLog("start skipped, no media")
                return
            }

            player.drawable = videoView
            player.play()
        }

        func stop() {
            isActive = false
            reconnectTask?.cancel()
            reconnectTask = nil
            hasPlayed = false
            lastReportedState = .connecting
            player.stop()
            player.drawable = nil
            debugLog("stop")
        }

        nonisolated func mediaPlayerStateChanged(_ notification: Notification) {
            guard let player = notification.object as? VLCMediaPlayer else { return }

            let state = player.state
            let stateName = VLCMediaPlayerStateToString(state)
            let hasVideoOut = player.hasVideoOut
            let isShowingVideo = state == .playing
                || state == .esAdded
                || (state == .buffering && hasVideoOut)
            let isWaitingForVideo = state == .opening
                || (state == .buffering && !hasVideoOut)
            let didFail = state == .error || state == .ended || state == .stopped

            Task { @MainActor [weak self] in
                self?.handleState(
                    name: stateName,
                    hasVideoOut: hasVideoOut,
                    isShowingVideo: isShowingVideo,
                    isWaitingForVideo: isWaitingForVideo,
                    didFail: didFail
                )
            }
        }

        nonisolated func mediaPlayerTimeChanged(_ notification: Notification) {
            Task { @MainActor [weak self] in
                self?.markPlaying()
                self?.logProgress()
            }
        }

        private func handleState(
            name: String,
            hasVideoOut: Bool,
            isShowingVideo: Bool,
            isWaitingForVideo: Bool,
            didFail: Bool
        ) {
            if lastStateLog?.name != name
                || lastStateLog?.hasVideoOut != hasVideoOut {
                lastStateLog = (name, hasVideoOut)
                debugLog("state=\(name) videoOut=\(hasVideoOut)")
            }
            guard isActive else { return }

            if isShowingVideo {
                markPlaying()
            } else if didFail {
                if hasPlayed {
                    report(.reconnecting)
                    scheduleReconnect()
                } else {
                    report(.connecting)
                    debugLog("retry paused before first frame")
                }
            } else if isWaitingForVideo, !hasPlayed {
                report(.connecting)
            }
        }

        private func markPlaying() {
            guard isActive else { return }
            reconnectTask?.cancel()
            reconnectTask = nil
            hasPlayed = true
            report(.playing)
        }

        private func report(_ state: PlaybackState) {
            guard lastReportedState != state else { return }
            lastReportedState = state
            onStateChange(state)
        }

        private func scheduleReconnect() {
            guard reconnectTask == nil else { return }

            reconnectTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.isActive else { return }

                self.reconnectTask = nil
                self.debugLog("retry")
                self.player.play()
            }
        }

        private func logProgress() {
#if DEBUG
            let now = Date()
            guard now.timeIntervalSince(lastProgressLog) >= 5 else { return }
            lastProgressLog = now

            let statistics = player.media?.statistics
            debugLog(
                "progress timeMs=\(player.time.intValue) "
                    + "readBytes=\(statistics?.readBytes ?? 0) "
                    + "decoded=\(statistics?.decodedVideo ?? 0) "
                    + "displayed=\(statistics?.displayedPictures ?? 0) "
                    + "lost=\(statistics?.lostPictures ?? 0)"
            )
#endif
        }

        private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
            print("[Meerkat][Playback][\(cameraID)] \(message())")
#endif
        }
    }
}
