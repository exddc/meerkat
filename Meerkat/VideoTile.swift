import AppKit
import SwiftUI
import VLCKitSPM

struct VideoTile: View {
    let camera: Camera
    let isActive: Bool
    let playbackEnabled: Bool

    @State private var playbackState = PlaybackState.connecting

    init(camera: Camera, isActive: Bool, playbackEnabled: Bool = true) {
        self.camera = camera
        self.isActive = isActive
        self.playbackEnabled = playbackEnabled
    }

    var body: some View {
        ZStack {
            if playbackEnabled {
                VideoPlayerView(
                    camera: camera,
                    isActive: isActive,
                    onStateChange: { playbackState = $0 }
                )
            } else {
                Color.black
            }

            GlassEffectContainer(spacing: 4) {
                ZStack {
                    if playbackEnabled, isActive, let status = playbackState.status {
                        HStack(spacing: 6) {
                            Image(systemName: status.symbol)

                            Text(status.text)
                        }
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .glassEffect(.regular, in: .rect(cornerRadius: 8))
                        .accessibilityIdentifier("\(camera.id)-status")
                    }

                    VStack {
                        Spacer()

                        HStack {
                            Text(camera.name)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .glassEffect(.regular, in: .rect(cornerRadius: 8))
                                .accessibilityIdentifier("\(camera.id)-name")

                            Spacer()
                        }
                    }
                    .padding(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(.black)
        .clipShape(.rect(cornerRadius: 12))
        .onChange(of: isActive) { _, active in
            if !active {
                playbackState = .connecting
            }
        }
        .onDisappear {
            playbackState = .connecting
        }
    }
}

private enum PlaybackState: Equatable {
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

private struct VideoPlayerView: NSViewRepresentable {
    let camera: Camera
    let isActive: Bool
    let onStateChange: @MainActor (PlaybackState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(camera: camera, onStateChange: onStateChange)
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
        context.coordinator.setActive(isActive, in: videoView)
    }

    static func dismantleNSView(_ videoView: VLCVideoView, coordinator: Coordinator) {
        coordinator.stop()
    }

    private func configureAccessibility(for videoView: VLCVideoView) {
        videoView.setAccessibilityElement(true)
        videoView.setAccessibilityRole(.group)
        videoView.setAccessibilityLabel("\(camera.name) video")
        videoView.setAccessibilityIdentifier("\(camera.id)-video")
    }

    @MainActor
    final class Coordinator: NSObject, VLCMediaPlayerDelegate {
        var onStateChange: @MainActor (PlaybackState) -> Void

        private let player: VLCMediaPlayer
        private let cameraID: String
        private let endpoint: String
        private var isActive = false
        private var hasPlayed = false
        private var lastReportedState = PlaybackState.connecting
        private var lastProgressLog = Date.distantPast
        private var lastStateLog: (name: String, hasVideoOut: Bool)?
        private var reconnectTask: Task<Void, Never>?

        init(
            camera: Camera,
            onStateChange: @escaping @MainActor (PlaybackState) -> Void
        ) {
            CameraCertificateTrust.shared.activate()
            player = VLCMediaPlayer(library: CameraCertificateTrust.shared.library)
            cameraID = camera.id
            endpoint = camera.logEndpoint
            self.onStateChange = onStateChange
            super.init()

            let media = VLCMedia(url: camera.streamURL)
            media.addOption(":no-audio")
            media.addOption(":network-caching=300")
            if camera.streamURL.path == "/flv" {
                media.addOption(":http-continuous")
            }
            player.media = media
            player.delegate = self
            debugLog("initialized endpoint=\(endpoint)")
        }

        func setActive(_ active: Bool, in videoView: VLCVideoView) {
            guard active != isActive else { return }
            isActive = active

            if active {
                debugLog("start")
                lastReportedState = .connecting
                onStateChange(.connecting)
                player.drawable = videoView
                player.play()
            } else {
                stop()
            }
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

@MainActor
private final class CameraCertificateTrust: NSObject, @MainActor VLCCustomDialogRendererProtocol {
    static let shared = CameraCertificateTrust(cameras: CameraCatalog.bundled)

    private let allowedHosts: Set<String>
    private let redactions: [(value: String, replacement: String)]
    private let logger: RedactedVLCLogger
    let library: VLCLibrary
    private var dialogProvider: VLCDialogProvider!

    private init(cameras: [Camera]) {
        allowedHosts = Set(
            cameras.compactMap { camera in
                guard camera.streamURL.path == "/flv" else { return nil }
                return camera.streamURL.host
            }
        )
        redactions = cameras.flatMap { camera in
            var values = [(camera.streamURL.absoluteString, camera.logEndpoint)]
            let components = URLComponents(
                url: camera.streamURL,
                resolvingAgainstBaseURL: false
            )

            for item in components?.queryItems ?? [] {
                if ["user", "password"].contains(item.name),
                   let value = item.value,
                   !value.isEmpty {
                    values.append((value, "<redacted>"))
                }
            }

            for item in components?.percentEncodedQueryItems ?? [] {
                if ["user", "password"].contains(item.name),
                   let value = item.value,
                   !value.isEmpty {
                    values.append((value, "<redacted>"))
                }
            }

            return values
        }
        logger = RedactedVLCLogger(redactions: redactions)
        library = VLCLibrary(options: ["--no-drop-late-frames"])
        super.init()

#if DEBUG
        library.loggers = [logger]
#endif
        dialogProvider = VLCDialogProvider(library: library, customUI: true)
        dialogProvider.customRenderer = self
    }

    func activate() {}

    func showError(withTitle error: String, message: String) {
        debugLog("error title=\(sanitized(error)) message=\(sanitized(message))")
    }

    func showLogin(
        withTitle title: String,
        message: String,
        defaultUsername username: String?,
        askingForStorage: Bool,
        withReference reference: NSValue
    ) {
        debugLog("unexpected login request dismissed")
        dialogProvider.dismissDialog(withReference: reference)
    }

    func showQuestion(
        withTitle title: String,
        message: String,
        type questionType: VLCDialogQuestionType,
        cancel cancelString: String?,
        action1String: String?,
        action2String: String?,
        withReference reference: NSValue
    ) {
        guard action1String != nil,
              let host = allowedHosts.first(where: message.contains) else {
            debugLog("unrecognized question dismissed")
            dialogProvider.dismissDialog(withReference: reference)
            return
        }

        debugLog("accepting temporary certificate host=\(host)")
        dialogProvider.postAction(1, forDialogReference: reference)
    }

    func showProgress(
        withTitle title: String,
        message: String,
        isIndeterminate: Bool,
        position: Float,
        cancel cancelString: String?,
        withReference reference: NSValue
    ) {}

    func updateProgress(
        withReference reference: NSValue,
        message: String?,
        position: Float
    ) {}

    func cancelDialog(withReference reference: NSValue) {
        dialogProvider.dismissDialog(withReference: reference)
    }

    private func debugLog(_ message: @autoclosure () -> String) {
#if DEBUG
        print("[Meerkat][TLS] \(message())")
#endif
    }

    private func sanitized(_ text: String) -> String {
        redactions.reduce(text) { result, redaction in
            result.replacingOccurrences(
                of: redaction.value,
                with: redaction.replacement
            )
        }
    }
}

private final class RedactedVLCLogger: NSObject, VLCLogging {
    var level = VLCLogLevel.debug

    private let redactions: [(value: String, replacement: String)]

    init(redactions: [(value: String, replacement: String)]) {
        self.redactions = redactions.flatMap { redaction in
            guard let encoded = redaction.value.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics
            ) else {
                return [redaction]
            }

            return [redaction, (encoded, redaction.replacement)]
        }
    }

    func handleMessage(
        _ message: String,
        logLevel: VLCLogLevel,
        context: VLCLogContext?
    ) {
#if DEBUG
        if message.contains("GET /flv") {
            print(
                "[Meerkat][VLC][http] camera request "
                    + "literalBang=\(message.contains("!")) "
                    + "encodedBang=\(message.localizedCaseInsensitiveContains("%21"))"
            )
        }

        let safeMessage = redactions.reduce(message) { result, redaction in
            result.replacingOccurrences(
                of: redaction.value,
                with: redaction.replacement
            )
        }
        let keywords = [
            "access",
            "authentication",
            "certificate",
            "clock",
            "connection",
            "http",
            "jitter",
            "PCR",
            "request",
            "response",
            "timestamp",
            "tls",
        ]
        guard keywords.contains(where: safeMessage.localizedCaseInsensitiveContains) else {
            return
        }
        print("[Meerkat][VLC][\(context?.module ?? "unknown")] \(safeMessage)")
#endif
    }
}
