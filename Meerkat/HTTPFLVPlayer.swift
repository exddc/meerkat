import AVFoundation
import Foundation

@MainActor
final class HTTPFLVPlayer: NSObject, URLSessionDataDelegate {
    static let retryDelay = Duration.seconds(2)
    static let failureRetryDelay = Duration.seconds(30)
    static let stallTimeout: TimeInterval = 10
    static let maximumPendingBytes = 4 * 1024 * 1024
    var stallTimeout: TimeInterval = HTTPFLVPlayer.stallTimeout
    var maximumPendingBytes: Int = HTTPFLVPlayer.maximumPendingBytes
    private static let untrustedCertificateCodes: [URLError.Code] = [
        .serverCertificateUntrusted, .serverCertificateHasBadDate,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
    ]

    private let url: URL
    private let configuration: URLSessionConfiguration
    private let renderer: AVSampleBufferVideoRenderer
    private let timebase: CMTimebase
    private let onStateChange: (PlaybackState) -> Void
    private var session: URLSession?
    private var stream: URLSessionDataTask?
    private var parser = FLVParser()
    private var builder = AVCSampleBuilder()
    private var clock = PlaybackClock()
    private var retry: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastFrame = Date()
    private var active = false
    private var state = PlaybackState.connecting
    private var pendingSamples = [CMSampleBuffer]()
    private var pendingBytes = 0
    private var requestingMedia = false

    init(url: URL, displayLayer: AVSampleBufferDisplayLayer,
         configuration: URLSessionConfiguration = .ephemeral,
         onStateChange: @escaping (PlaybackState) -> Void) throws {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = Self.stallTimeout
        configuration.timeoutIntervalForResource = .infinity
        self.configuration = configuration
        self.url = url
        renderer = displayLayer.sampleBufferRenderer
        timebase = try CMTimebase(sourceClock: CMClock.hostTimeClock)
        self.onStateChange = onStateChange
        displayLayer.controlTimebase = timebase
    }

    func start() {
        guard !active else { return }
        active = true
        connect()
    }

    func stop() {
        active = false
        retry?.cancel()
        retry = nil
        disconnect()
    }

    private func disconnect() {
        watchdog?.cancel()
        watchdog = nil
        stream?.cancel()
        stream = nil
        session?.invalidateAndCancel()
        session = nil
        parser = FLVParser()
        builder = AVCSampleBuilder()
        clock.reset()
        renderer.stopRequestingMediaData()
        requestingMedia = false
        pendingSamples.removeAll(keepingCapacity: false)
        pendingBytes = 0
        CMTimebaseSetRate(timebase, rate: 0)
        renderer.flush(removingDisplayedImage: true)
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
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                if Date().timeIntervalSince(self.lastFrame) > self.stallTimeout || self.renderer.status == .failed {
                    self.fail(.reconnecting)
                    return
                }
            }
        }
    }

    private func fail(_ failure: PlaybackState) {
        guard active, retry == nil else { return }
        disconnect()
        report(failure)
        let delay = failure == .reconnecting ? Self.retryDelay : Self.failureRetryDelay
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

    private func enqueue(_ sample: CMSampleBuffer) {
        pendingSamples.append(sample)
        pendingBytes += CMSampleBufferGetTotalSampleSize(sample)
        drainSamples()
    }

    private func drainSamples() {
        guard active else { return }
        guard renderer.status != .failed else { fail(.reconnecting); return }
        while renderer.isReadyForMoreMediaData, let sample = pendingSamples.first {
            pendingSamples.removeFirst()
            pendingBytes -= CMSampleBufferGetTotalSampleSize(sample)
            synchronizeClock(with: sample)
            renderer.enqueue(sample)
            lastFrame = Date()
            if renderer.status == .rendering { report(.playing) }
        }
        if pendingSamples.isEmpty {
            guard requestingMedia else { return }
            renderer.stopRequestingMediaData()
            requestingMedia = false
        } else if !requestingMedia {
            requestingMedia = true
            renderer.requestMediaDataWhenReady(on: .main) { [weak self] in
                MainActor.assumeIsolated { self?.drainSamples() }
            }
        }
    }

    private func synchronizeClock(with sample: CMSampleBuffer) {
        let decode = CMSampleBufferGetDecodeTimeStamp(sample)
        guard let time = clock.anchor(decode: decode, now: CMTimebaseGetTime(timebase)) else { return }
        CMTimebaseSetTime(timebase, time: time)
        CMTimebaseSetRate(timebase, rate: 1)
    }

    private func report(_ newState: PlaybackState) {
        guard state != newState else { return }
        state = newState
        onStateChange(newState)
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            guard active, dataTask === stream else { return }
            do {
                for tag in try parser.append(data) {
                    guard dataTask === stream else { return }
                    guard let sample = try builder.sample(for: tag) else { continue }
                    guard pendingBytes + CMSampleBufferGetTotalSampleSize(sample) <= maximumPendingBytes else {
                        fail(.reconnecting)
                        return
                    }
                    enqueue(sample)
                }
            } catch FLVError.unsupportedCodec, FLVError.invalidHeader {
                fail(.unsupported)
            } catch {
                fail(.reconnecting)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
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

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard active, task === stream else { return }
            fail(with: error)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    nonisolated func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
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
