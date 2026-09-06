import SwiftUI

struct VideoTile: View {
    let camera: Camera
    let isActive: Bool
    let playbackEnabled: Bool
    let fillsAvailableSpace: Bool

    @AppStorage(AppInfo.cameraLabelVisibilityKey) private var cameraLabelVisibility = CameraLabelVisibility.always
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var playbackState = PlaybackState.connecting
    @State private var isHovering = false

    init(
        camera: Camera,
        isActive: Bool,
        playbackEnabled: Bool = true,
        fillsAvailableSpace: Bool = false
    ) {
        self.camera = camera
        self.isActive = isActive
        self.playbackEnabled = playbackEnabled
        self.fillsAvailableSpace = fillsAvailableSpace
    }

    private var showsCameraLabel: Bool {
        cameraLabelVisibility.isVisible(isHovering: isHovering)
    }

    private var labelAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.2)
    }

    var body: some View {
        ZStack {
            if playbackEnabled {
                VideoPlayerView(
                    camera: camera,
                    streamURLString: camera.streamURLString,
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
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .videoOverlay()
                        .accessibilityIdentifier("\(camera.cameraID.uuidString)-status")
                    }

                    if showsCameraLabel {
                        VStack {
                            Spacer()

                            HStack {
                                Text(camera.name)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .videoOverlay()
                                    .accessibilityIdentifier("\(camera.cameraID.uuidString)-name")

                                Spacer()
                            }
                        }
                        .padding(8)
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(labelAnimation, value: showsCameraLabel)
            }
            .environment(\.colorScheme, .dark)
        }
        .modifier(VideoTileSizing(fillsAvailableSpace: fillsAvailableSpace))
        .background(.black)
        .clipShape(.rect(cornerRadius: 12))
        .onHover { isHovering = $0 }
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

private struct VideoTileSizing: ViewModifier {
    let fillsAvailableSpace: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if fillsAvailableSpace {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content.aspectRatio(16 / 9, contentMode: .fit)
        }
    }
}

#Preview("Light") {
    VideoTile(
        camera: Camera(
            name: "Front Door",
            streamURLString: "https://camera.test/live"
        ),
        isActive: true,
        playbackEnabled: false
    )
    .frame(width: 320)
    .padding()
    .preferredColorScheme(.light)
}

#Preview("Dark") {
    VideoTile(
        camera: Camera(
            name: "Front Door",
            streamURLString: "https://camera.test/live"
        ),
        isActive: true,
        playbackEnabled: false
    )
    .frame(width: 320)
    .padding()
    .preferredColorScheme(.dark)
}
