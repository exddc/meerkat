import AVFoundation

@MainActor
protocol CameraIngest: AnyObject {
    func start()
    func stop()
    func attachDisplay(
        _ displayLayer: AVSampleBufferDisplayLayer,
        onStateChange: @escaping (PlaybackState) -> Void
    ) throws
    func detachDisplay(_ displayLayer: AVSampleBufferDisplayLayer?)
}

struct AVCGOPBuffer {
    let maximumBytes: Int

    private(set) var samples = [CMSampleBuffer]()
    private(set) var byteCount = 0

    init(maximumBytes: Int = 1024 * 1024) {
        self.maximumBytes = maximumBytes
    }

    mutating func append(_ sample: CMSampleBuffer) {
        let size = CMSampleBufferGetTotalSampleSize(sample)
        if sample.isSyncSample {
            guard size <= maximumBytes else {
                reset()
                return
            }
            samples = [sample]
            byteCount = size
            return
        }

        guard !samples.isEmpty else { return }
        guard byteCount + size <= maximumBytes else {
            reset()
            return
        }
        samples.append(sample)
        byteCount += size
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: false)
        byteCount = 0
    }
}

@MainActor
final class SampleBufferDisplaySink {
    static let maximumPendingBytes = 4 * 1024 * 1024
    static let maximumGOPBytes = 1024 * 1024
    static let displayLead = CMTime(value: 50, timescale: 1000)

    var maximumPendingBytes = SampleBufferDisplaySink.maximumPendingBytes
    private(set) var enqueuedSampleCount = 0
    var bufferedSampleCount: Int { gop.samples.count }
    var bufferedByteCount: Int { gop.byteCount }

    private var gop = AVCGOPBuffer(maximumBytes: SampleBufferDisplaySink.maximumGOPBytes)
    private var display: DisplayContext?
    private var pendingSamples = [CMSampleBuffer]()
    private var pendingBytes = 0
    private var requestingMedia = false
    private var onStateChange: ((PlaybackState) -> Void)?
    private let onFailure: (PlaybackState) -> Void

    init(onFailure: @escaping (PlaybackState) -> Void) {
        self.onFailure = onFailure
    }

    func attach(
        _ displayLayer: AVSampleBufferDisplayLayer,
        state: PlaybackState,
        onStateChange: @escaping (PlaybackState) -> Void
    ) throws {
        detach()
        let timebase = try CMTimebase(sourceClock: CMClock.hostTimeClock)
        displayLayer.controlTimebase = timebase
        display = DisplayContext(
            layer: displayLayer,
            renderer: displayLayer.sampleBufferRenderer,
            timebase: timebase
        )
        self.onStateChange = onStateChange
        onStateChange(state)
        if let latestSample = gop.samples.last, var display {
            try display.timeline.anchor(
                latestSample,
                now: CMClockGetTime(CMClock.hostTimeClock),
                lead: Self.displayLead
            )
            self.display = display
        }
        for (index, sample) in gop.samples.enumerated() {
            try queue(sample, displayImmediately: index == gop.samples.indices.last)
        }
    }

    func detach(_ displayLayer: AVSampleBufferDisplayLayer? = nil) {
        guard let display else { return }
        guard displayLayer == nil || display.layer === displayLayer else { return }
        display.renderer.stopRequestingMediaData()
        requestingMedia = false
        pendingSamples.removeAll(keepingCapacity: false)
        pendingBytes = 0
        CMTimebaseSetRate(display.timebase, rate: 0)
        display.renderer.flush(removingDisplayedImage: true)
        self.display = nil
        onStateChange = nil
    }

    func accept(_ sample: CMSampleBuffer) throws {
        gop.append(sample)
        guard display != nil else { return }
        try queue(sample)
    }

    func report(_ state: PlaybackState) {
        onStateChange?(state)
    }

    func reset() {
        gop.reset()
        guard var display else { return }
        display.renderer.stopRequestingMediaData()
        requestingMedia = false
        pendingSamples.removeAll(keepingCapacity: false)
        pendingBytes = 0
        display.timeline.reset()
        self.display = display
        CMTimebaseSetRate(display.timebase, rate: 0)
        display.renderer.flush(removingDisplayedImage: true)
    }

    var rendererFailed: Bool {
        display?.renderer.status == .failed
    }

    private func queue(_ sample: CMSampleBuffer, displayImmediately: Bool = false) throws {
        guard var display else { return }
        let size = CMSampleBufferGetTotalSampleSize(sample)
        guard pendingBytes + size <= maximumPendingBytes else {
            onFailure(.reconnecting)
            return
        }
        let retimed = try display.timeline.retime(
            sample,
            now: CMClockGetTime(CMClock.hostTimeClock),
            lead: Self.displayLead
        )
        if displayImmediately {
            retimed.displayImmediately = true
        }
        self.display = display
        pendingSamples.append(retimed)
        pendingBytes += size
        drain()
    }

    private func drain() {
        guard let display else { return }
        guard display.renderer.status != .failed else {
            onFailure(.reconnecting)
            return
        }
        while display.renderer.isReadyForMoreMediaData, let sample = pendingSamples.first {
            pendingSamples.removeFirst()
            pendingBytes -= CMSampleBufferGetTotalSampleSize(sample)
            if CMTimebaseGetRate(display.timebase) == 0 {
                CMTimebaseSetTime(display.timebase, time: CMClockGetTime(CMClock.hostTimeClock))
                CMTimebaseSetRate(display.timebase, rate: 1)
            }
            display.renderer.enqueue(sample)
            enqueuedSampleCount += 1
        }
        if pendingSamples.isEmpty {
            guard requestingMedia else { return }
            display.renderer.stopRequestingMediaData()
            requestingMedia = false
        } else if !requestingMedia {
            requestingMedia = true
            display.renderer.requestMediaDataWhenReady(on: .main) { [weak self] in
                MainActor.assumeIsolated { self?.drain() }
            }
        }
    }
}

private struct DisplayContext {
    let layer: AVSampleBufferDisplayLayer
    let renderer: AVSampleBufferVideoRenderer
    let timebase: CMTimebase
    var timeline = DisplayTimeline()
}

private struct DisplayTimeline {
    private var offset: CMTime?

    mutating func anchor(_ sample: CMSampleBuffer, now: CMTime, lead: CMTime) throws {
        offset = now + lead - (try sourceAnchor(for: sample))
    }

    mutating func retime(_ sample: CMSampleBuffer, now: CMTime, lead: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo()
        let status = CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing)
        guard status == noErr else { throw SampleBufferDisplayError.coreMedia(status) }
        if offset == nil {
            offset = now + lead - (try sourceAnchor(for: sample))
        }
        guard let offset else { throw SampleBufferDisplayError.missingTimestamp }
        if timing.decodeTimeStamp.isValid {
            timing.decodeTimeStamp = timing.decodeTimeStamp + offset
        }
        if timing.presentationTimeStamp.isValid {
            timing.presentationTimeStamp = timing.presentationTimeStamp + offset
        }
        var copy: CMSampleBuffer?
        let copyStatus = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &copy
        )
        guard copyStatus == noErr, let copy else {
            throw SampleBufferDisplayError.coreMedia(copyStatus)
        }
        return copy
    }

    mutating func reset() {
        offset = nil
    }

    private func sourceAnchor(for sample: CMSampleBuffer) throws -> CMTime {
        let decodeTime = CMSampleBufferGetDecodeTimeStamp(sample)
        if decodeTime.isValid {
            return decodeTime
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
        guard presentationTime.isValid else { throw SampleBufferDisplayError.missingTimestamp }
        return presentationTime
    }
}

private enum SampleBufferDisplayError: Error {
    case coreMedia(OSStatus)
    case missingTimestamp
}

extension CMSampleBuffer {
    var isSyncSample: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            self,
            createIfNecessary: false
        ) as? [[String: Any]], let attachment = attachments.first else {
            return true
        }
        return attachment[kCMSampleAttachmentKey_NotSync as String] as? Bool != true
    }

    var displayImmediately: Bool {
        get {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                self,
                createIfNecessary: false
            ) as? [[String: Any]], let attachment = attachments.first else {
                return false
            }
            return attachment[kCMSampleAttachmentKey_DisplayImmediately as String] as? Bool == true
        }
        set {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                self,
                createIfNecessary: true
            ) else { return }
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0),
                to: CFMutableDictionary.self
            )
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(newValue ? kCFBooleanTrue : kCFBooleanFalse).toOpaque()
            )
        }
    }
}
