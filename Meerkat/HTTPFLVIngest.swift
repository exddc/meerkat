import AVFoundation
import Foundation

@MainActor
final class HTTPFLVIngest: NSObject, CameraIngest, URLSessionDataDelegate {
    static let retryDelay = Duration.seconds(2)
    static let failureRetryDelay = Duration.seconds(30)
    static let stallTimeout: TimeInterval = 10
    static let maximumPendingBytes = SampleBufferDisplaySink.maximumPendingBytes
    static let maximumGOPBytes = SampleBufferDisplaySink.maximumGOPBytes

    var stallTimeout: TimeInterval = HTTPFLVIngest.stallTimeout
    var maximumPendingBytes: Int {
        get { output.maximumPendingBytes }
        set { output.maximumPendingBytes = newValue }
    }
    var retryDelay = HTTPFLVIngest.retryDelay
    var failureRetryDelay = HTTPFLVIngest.failureRetryDelay
    var enqueuedSampleCount: Int { output.enqueuedSampleCount }
    var bufferedSampleCount: Int { output.bufferedSampleCount }
    var bufferedByteCount: Int { output.bufferedByteCount }

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
    private lazy var output = SampleBufferDisplaySink { [weak self] failure in
        self?.fail(failure)
    }
    private var retry: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastFrame = Date()
    private var active = false
    private var state = PlaybackState.connecting

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
        try output.attach(displayLayer, state: state, onStateChange: onStateChange)
    }

    func detachDisplay(_ displayLayer: AVSampleBufferDisplayLayer? = nil) {
        output.detach(displayLayer)
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
                let rendererFailed = self.output.rendererFailed
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
            output.reset()
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
        try output.accept(sample)
        lastFrame = Date()
        if output.bufferedSampleCount > 0 {
            report(.playing)
        }
    }

    private func report(_ newState: PlaybackState) {
        guard state != newState else { return }
        state = newState
        output.report(newState)
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
