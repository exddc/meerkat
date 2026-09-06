import CoreMedia

struct PlaybackClock {
    static let targetBuffer = CMTime(value: 300, timescale: 1000)
    static let minimumLead = CMTime(value: -100, timescale: 1000)
    static let maximumLead = CMTime(value: 1000, timescale: 1000)

    private var isRunning = false

    mutating func anchor(decode: CMTime, now: CMTime) -> CMTime? {
        let lead = decode - now
        guard !isRunning || lead < Self.minimumLead || lead > Self.maximumLead else { return nil }
        isRunning = true
        return decode - Self.targetBuffer
    }

    mutating func reset() {
        isRunning = false
    }
}
