enum PlaybackState: Equatable {
    case connecting
    case reconnecting
    case playing
    case unauthorized
    case unsupported
    case untrusted

    var status: (symbol: String, text: String)? {
        switch self {
        case .connecting:
            ("antenna.radiowaves.left.and.right", "Connecting…")
        case .reconnecting:
            ("arrow.clockwise", "Reconnecting…")
        case .playing:
            nil
        case .unauthorized:
            ("lock.slash", "Check credentials")
        case .unsupported:
            ("video.slash", "Unsupported stream")
        case .untrusted:
            ("lock.trianglebadge.exclamationmark", "Untrusted certificate")
        }
    }
}
