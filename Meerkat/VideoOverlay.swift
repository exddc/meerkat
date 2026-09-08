import SwiftUI

extension View {
    func videoOverlay(interactive: Bool = false) -> some View {
        modifier(VideoOverlayModifier(interactive: interactive))
    }
}

private struct VideoOverlayModifier: ViewModifier {
    var interactive: Bool

    func body(content: Content) -> some View {
        let shape = ConcentricRectangle(corners: .concentric(minimum: 8))
        let overlay = content.foregroundStyle(.white)
        Group {
            if interactive {
                overlay.glassEffect(.regular.interactive(), in: shape)
            } else {
                overlay.glassEffect(.regular, in: shape)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

#Preview("On Dark") {
    overlayPreview(on: .black)
        .preferredColorScheme(.light)
}

#Preview("On Light") {
    overlayPreview(on: .white)
        .preferredColorScheme(.light)
}

#Preview("On Color") {
    overlayPreview(on: .orange)
        .preferredColorScheme(.light)
}

private func overlayPreview(on color: Color) -> some View {
    HStack(spacing: 8) {
        Text("Camera 1")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .videoOverlay()

        Image(systemName: "gearshape")
            .font(.caption.weight(.medium))
            .padding(8)
            .videoOverlay(interactive: true)
    }
    .padding(20)
    .frame(width: 280, height: 120)
    .background(color)
}
