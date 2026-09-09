import AVFoundation
import Foundation

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
final class HTTPFLVIngest: NSObject, URLSessionDataDelegate {
    static let retryDelay = Duration.seconds(2)
    static let failureRetryDelay = Duration.seconds(30)
    static let stallTimeout: TimeInterval = 10
    static let maximumPendingBytes = 4 * 1024 * 1024
    static let maximumGOPBytes = 1024 * 1024
    static let displayLead = CMTime(value: 50, timescale: 1000)

    var stallTimeout: TimeInterval = HTTPFLVIngest.stallTimeout
    var maximumPendingBytes = HTTPFLVIngest.maximumPendingBytes
    var retryDelay = HTTPFLVIngest.retryDelay
    var failureRetryDelay = HTTPFLVIngest.failureRetryDelay
    private(set) var enqueuedSampleCount = 0
    var bufferedSampleCount: Int { gop.samples.count }
    var bufferedByteCount: Int { gop.byteCount }

    private static let untrustedCertificateCodes: [URLError.Code] = [
        .serverCertificateUntrusted, .serverCertificateHasBadDate,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
    ]

    private let url: URL
    private let configuration: URLSessionConfiguration
    private var session: URLSession?
    private var stream: URLSessionDataTask?
    private var parser = FLVParser()
    private var builder = AVCSampleBuilder()
    private var gop = AVCGOPBuffer(maximumBytes: HTTPFLVIngest.maximumGOPBytes)
    private var retry: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastFrame = Date()
    private var active = false
    private var state = PlaybackState.connecting
    private var display: DisplayContext?
    private var pendingSamples = [CMSampleBuffer]()
    private var pendingBytes = 0
    private var requestingMedia = false
    private var onStateChange: ((PlaybackState) -> Void)?

    init(url: URL, configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = Self.stallTimeout
        configuration.timeoutIntervalForResource = .infinity
        self.configuration = configuration
        self.url = url
    }

    func start() {
        guard !active else { return }
        active = true
        state = .connecting
        connect()
    }

    func stop() {
        active = false
        retry?.cancel()
        retry = nil
        disconnect(clearGOP: true)
        detachDisplay()
    }

    func attachDisplay(
        _ displayLayer: AVSampleBufferDisplayLayer,
        onStateChange: @escaping (PlaybackState) -> Void
    ) throws {
        detachDisplay()
        let timebase = try CMTimebase(sourceClock: CMClock.hostTimeClock)
        displayLayer.controlTimebase = timebase
        display = DisplayContext(
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
        for sample in gop.samples {
            try queueForDisplay(sample, displayImmediately: true)
        }
    }

    func detachDisplay() {
        guard let display else { return }
        display.renderer.stopRequestingMediaData()
        requestingMedia = false
        pendingSamples.removeAll(keepingCapacity: false)
        pendingBytes = 0
        CMTimebaseSetRate(display.timebase, rate: 0)
        display.renderer.flush(removingDisplayedImage: true)
        self.display = nil
        onStateChange = nil
    }

    private func connect() {
        guard active else { return }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("video/x-flv", forHTTPHeaderField: "Accept")
        stream = session.dataTask(with: request)
        lastFrame = Date()
        stream?.resume()
        let tick = min(1, max(stallTimeout / 5, 0.05))
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(tick))
                guard !Task.isCancelled, let self else { return }
                let rendererFailed = self.display?.renderer.status == .failed
                if Date().timeIntervalSince(self.lastFrame) > self.stallTimeout || rendererFailed {
                    self.fail(.reconnecting)
                    return
                }
            }
        }
    }

    private func disconnect(clearGOP: Bool) {
        watchdog?.cancel()
        watchdog = nil
        stream?.cancel()
        stream = nil
        session?.invalidateAndCancel()
        session = nil
        parser = FLVParser()
        builder = AVCSampleBuilder()
        if clearGOP {
            gop.reset()
            resetDisplay()
        }
    }

    private func fail(_ failure: PlaybackState) {
        guard active, retry == nil else { return }
        disconnect(clearGOP: true)
        report(failure)
        let delay = failure == .reconnecting ? retryDelay : failureRetryDelay
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.retry = nil
            self.connect()
        }
    }

    private func fail(with error: Error?) {
        if let code = (error as? URLError)?.code, Self.untrustedCertificateCodes.contains(code) {
            fail(.untrusted)
        } else {
            fail(.reconnecting)
        }
    }

    private func accept(_ sample: CMSampleBuffer) throws {
        gop.append(sample)
        lastFrame = Date()
        if !gop.samples.isEmpty {
            report(.playing)
        }
        guard display != nil else { return }
        try queueForDisplay(sample)
    }

    private func queueForDisplay(
        _ sample: CMSampleBuffer,
        displayImmediately: Bool = false
    ) throws {
        guard var display else { return }
        let size = CMSampleBufferGetTotalSampleSize(sample)
        guard pendingBytes + size <= maximumPendingBytes else {
            fail(.reconnecting)
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
        drainSamples()
    }

    private func drainSamples() {
        guard active, let display else { return }
        guard display.renderer.status != .failed else {
            fail(.reconnecting)
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
                MainActor.assumeIsolated { self?.drainSamples() }
            }
        }
    }

    private func resetDisplay() {
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

    private func report(_ newState: PlaybackState) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            guard active, dataTask === stream else { return }
            do {
                for tag in try parser.append(data) {
                    guard dataTask === stream else { return }
                    guard let sample = try builder.sample(for: tag) else { continue }
                    try accept(sample)
                }
            } catch FLVError.unsupportedCodec, FLVError.invalidHeader {
                fail(.unsupported)
            } catch {
                fail(.reconnecting)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        MainActor.assumeIsolated {
            guard active, dataTask === stream, let response = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                return
            }
            switch response.statusCode {
            case 200:
                completionHandler(.allow)
            case 401, 403:
                completionHandler(.cancel)
                fail(.unauthorized)
            case 429, 500...:
                completionHandler(.cancel)
                fail(.reconnecting)
            default:
                completionHandler(.cancel)
                fail(.unsupported)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        MainActor.assumeIsolated {
            guard active, task === stream else { return }
            fail(with: error)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        MainActor.assumeIsolated {
            guard active, session === self.session,
                  challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  CameraCertificateTrust.allows(url: url, host: challenge.protectionSpace.host),
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
}

private struct DisplayContext {
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
        guard status == noErr else { throw FLVError.coreMedia(status) }
        if offset == nil {
            offset = now + lead - (try sourceAnchor(for: sample))
        }
        guard let offset else { throw FLVError.invalidAVC }
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
        guard copyStatus == noErr, let copy else { throw FLVError.coreMedia(copyStatus) }
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
        guard presentationTime.isValid else { throw FLVError.invalidAVC }
        return presentationTime
    }
}

private extension CMSampleBuffer {
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
