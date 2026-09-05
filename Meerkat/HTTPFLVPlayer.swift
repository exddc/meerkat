import AVFoundation
import Foundation

@MainActor
final class HTTPFLVPlayer: NSObject, URLSessionDataDelegate {
    private let url: URL
    private let configuration: URLSessionConfiguration
    private let renderer: AVSampleBufferVideoRenderer
    private let onStateChange: (PlaybackState) -> Void
    private var session: URLSession?
    private var stream: URLSessionDataTask?
    private var parser = FLVParser()
    private var builder = AVCSampleBuilder()
    private var retry: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var lastFrame = Date()
    private var active = false
    private var state = PlaybackState.connecting
    private var pendingSamples = [CMSampleBuffer]()
    private var pendingBytes = 0
    private var requestingMedia = false

    init(url: URL, renderer: AVSampleBufferVideoRenderer,
         configuration: URLSessionConfiguration = .ephemeral,
         onStateChange: @escaping (PlaybackState) -> Void) {
        self.configuration = configuration
        self.url = url
        self.renderer = renderer
        self.onStateChange = onStateChange
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
        renderer.stopRequestingMediaData()
        requestingMedia = false
        pendingSamples.removeAll(keepingCapacity: false)
        pendingBytes = 0
        renderer.flush(removingDisplayedImage: true)
    }

    private func connect() {
        guard active else { return }
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = .infinity
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
                if Date().timeIntervalSince(self.lastFrame) > 10 || self.renderer.status == .failed {
                    self.reconnect()
                    return
                }
            }
        }
    }

    private func reconnect() {
        guard active, retry == nil else { return }
        disconnect()
        report(.reconnecting)
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.retry = nil
            self.connect()
        }
    }

    private func requestMedia() {
        guard !requestingMedia else { return }
        requestingMedia = true
        renderer.requestMediaDataWhenReady(on: .main) { [weak self] in
            MainActor.assumeIsolated { self?.drainSamples() }
        }
    }

    private func drainSamples() {
        guard active else { return }
        guard renderer.status != .failed else { reconnect(); return }
        while renderer.isReadyForMoreMediaData, !pendingSamples.isEmpty {
            let sample = pendingSamples.removeFirst()
            pendingBytes -= CMSampleBufferGetTotalSampleSize(sample)
            renderer.enqueue(sample)
            lastFrame = Date()
            if renderer.status == .rendering { report(.playing) }
        }
        if pendingSamples.isEmpty {
            renderer.stopRequestingMediaData()
            requestingMedia = false
        }
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
                    if let sample = try builder.sample(for: tag) {
                        guard renderer.status != .failed, pendingSamples.count < 30,
                              pendingBytes + CMSampleBufferGetTotalSampleSize(sample) <= 4 * 1024 * 1024 else {
                            reconnect()
                            return
                        }
                        pendingSamples.append(sample)
                        pendingBytes += CMSampleBufferGetTotalSampleSize(sample)
                        requestMedia()
                    }
                }
            } catch {
                reconnect()
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        MainActor.assumeIsolated {
            guard active, dataTask === stream,
                  let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard active, task === stream else { return }
            reconnect()
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
