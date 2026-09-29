import AVFoundation
import Combine
import Foundation
import SwiftData

struct CameraInput: Equatable {
    var address: String
    var username = ""
    var password = ""
    var requiresAuthentication = true

    init(_ input: String) {
        address = input
        importCredentials()
    }

    init(playbackURLString: String, authenticationRequired: Bool?) {
        self.init(playbackURLString)
        requiresAuthentication = authenticationRequired
            ?? (playbackURLString.isEmpty || Self.containsCredentials(in: playbackURLString))
        address = Self.defaultReolinkAddress(from: playbackURLString) ?? address
    }

    mutating func importCredentials() {
        guard var components = Self.components(address) else { return }
        let items = components.queryItems ?? []
        let user = items.first { $0.name == "user" }
        let password = items.first { $0.name == "password" }
        guard user != nil || password != nil || components.user != nil || components.password != nil else { return }
        username = user?.value ?? components.user ?? ""
        self.password = password?.value ?? components.password ?? ""
        requiresAuthentication = true
        components.user = nil
        components.password = nil
        let remaining = items.filter { $0.name != "user" && $0.name != "password" }
        components.queryItems = remaining.isEmpty ? nil : remaining
        address = components.string ?? address
    }

    var streamURL: URL? {
        guard var components = Self.components(address) else { return nil }
        let isRTSP = components.scheme == "rtsp"
        if !isRTSP, components.path.isEmpty || components.path == "/" {
            components.path = "/flv"
        }
        var items = (components.queryItems ?? []).filter { $0.name != "user" && $0.name != "password" }
        if !isRTSP, components.path == "/flv" {
            for (name, value) in [("port", "1935"), ("app", "bcs"), ("stream", "channel0_sub.bcs")] {
                if !items.contains(where: { $0.name == name }) {
                    items.append(URLQueryItem(name: name, value: value))
                }
            }
        }
        if requiresAuthentication {
            if isRTSP {
                components.user = username
                components.password = password
            } else {
                items.append(URLQueryItem(name: "user", value: username))
                items.append(URLQueryItem(name: "password", value: password))
            }
        }
        components.queryItems = items.isEmpty ? nil : items
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        if !isRTSP {
            components.user = nil
            components.password = nil
        }
        components.fragment = nil
        return components.url
    }

    var completeStreamURL: URL? {
        guard !requiresAuthentication || (!username.isEmpty && !password.isEmpty) else { return nil }
        return streamURL
    }

    var completeStreamURLs: [URL] {
        guard !requiresAuthentication || (!username.isEmpty && !password.isEmpty),
              let streamURL else { return [] }
        guard usesEndpointDiscovery,
              let components = Self.components(address) else { return [streamURL] }
        let ports: [Int?] = components.port.map { [$0] } ?? [nil, 8554, 8555]
        let rtspURLs = ports.flatMap { port in
            ["/stream1", "/stream2", "/live0", "/live1"].compactMap { path in
                rtspURL(components: components, port: port, path: path)
            }
        }
        return [streamURL] + rtspURLs
    }

    var completeStreamURLGroups: [[URL]] {
        let urls = completeStreamURLs
        guard usesEndpointDiscovery else { return urls.isEmpty ? [] : [urls] }
        return [
            urls.filter { $0.path == "/flv" || $0.path == "/stream1" },
            urls.filter { $0.path == "/live0" },
            urls.filter { $0.path == "/stream2" },
            urls.filter { $0.path == "/live1" },
        ].filter { !$0.isEmpty }
    }

    var usesEndpointDiscovery: Bool {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.contains("://"), let components = Self.components(address) else { return false }
        return components.path.isEmpty || components.path == "/"
    }

    private func rtspURL(components: URLComponents, port: Int?, path: String) -> URL? {
        var components = components
        components.scheme = "rtsp"
        components.port = port
        components.path = path
        components.query = nil
        components.fragment = nil
        if requiresAuthentication {
            components.user = username
            components.password = password
        } else {
            components.user = nil
            components.password = nil
        }
        return components.url
    }

    private static func containsCredentials(in input: String) -> Bool {
        guard let components = components(input) else { return false }
        let items = components.queryItems ?? []
        return components.user != nil
            || components.password != nil
            || items.contains { $0.name == "user" || $0.name == "password" }
    }

    private static func defaultReolinkAddress(from input: String) -> String? {
        guard let components = components(input), components.path == "/flv" else { return nil }
        let items = (components.queryItems ?? []).filter { $0.name != "user" && $0.name != "password" }
        let defaults = [
            URLQueryItem(name: "port", value: "1935"),
            URLQueryItem(name: "app", value: "bcs"),
            URLQueryItem(name: "stream", value: "channel0_sub.bcs"),
        ]
        guard items.count == defaults.count, defaults.allSatisfy(items.contains) else { return nil }
        guard let host = components.host else { return nil }
        return components.port.map { "\(host):\($0)" } ?? host
    }

    private static func components(_ input: String) -> URLComponents? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains(where: { $0.isWhitespace }) else { return nil }
        let address = input.contains("://") ? input : "https://\(input)"
        guard var components = URLComponents(string: address),
              let scheme = components.scheme?.lowercased(), ["https", "rtsp"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        components.scheme = scheme
        return components
    }
}

@MainActor
final class CameraConfigurationEditor: ObservableObject {
    typealias EndpointCheck = @Sendable (URL) async throws -> Void

    @Published var input: CameraInput {
        didSet {
            guard input != oldValue else { return }
            scheduleUpdate()
        }
    }
    @Published private(set) var endpointError: String?

    private let camera: Camera
    private let requiresAttachedCamera: Bool
    private let debounceDuration: Duration
    private let endpointCheck: EndpointCheck
    private var updateRevision = 0
    private var updateTask: Task<Void, Never>?
    private var resolvedURL: URL?

    init(
        camera: Camera,
        debounceDuration: Duration = .milliseconds(700),
        endpointCheck: @escaping EndpointCheck = { url in
            try await CameraEndpointCheck(url: url).check()
        }
    ) {
        self.camera = camera
        requiresAttachedCamera = camera.modelContext != nil
        self.debounceDuration = debounceDuration
        self.endpointCheck = endpointCheck
        input = CameraInput(
            playbackURLString: camera.streamURLString,
            authenticationRequired: camera.authenticationRequired
        )
    }

    deinit {
        updateTask?.cancel()
    }

    func flush() {
        updateTask?.cancel()
        updateRevision &+= 1
        guard let url = resolvedURL ?? (input.usesEndpointDiscovery ? nil : input.completeStreamURL) else { return }
        persist(input, url: url)
    }

    private func scheduleUpdate() {
        updateTask?.cancel()
        updateRevision &+= 1
        resolvedURL = nil
        let revision = updateRevision
        let input = input
        let debounceDuration = debounceDuration
        let endpointCheck = endpointCheck
        let usedEndpoints = usedEndpointIdentities()
        endpointError = nil

        guard !input.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        updateTask = Task { [weak self] in
            do {
                try await Task.sleep(for: debounceDuration)
                try Task.checkCancellation()
                guard let url = input.streamURL else {
                    self?.setEndpointError("Enter a valid camera address.", for: revision)
                    return
                }
                let groups = input.completeStreamURLGroups
                guard !groups.isEmpty else {
                    self?.setEndpointError("Enter the camera username and password.", for: revision)
                    return
                }
                let candidateGroups = groups.compactMap { group in
                    let available = group.filter {
                        !usedEndpoints.contains(Self.endpointIdentity(for: $0))
                    }
                    return available.isEmpty ? nil : available
                }
                guard !candidateGroups.isEmpty else {
                    self?.setEndpointError("This camera is already added.", for: revision)
                    return
                }
                guard self?.updateRevision == revision else { return }
                if !input.usesEndpointDiscovery {
                    guard self?.persist(input, url: url) == true else { return }
                }

                let resolvedURL = try await Self.resolve(candidateGroups, using: endpointCheck)
                try Task.checkCancellation()
                guard self?.updateRevision == revision else { return }
                guard self?.persist(input, url: resolvedURL) == true else { return }
                self?.resolvedURL = resolvedURL
                self?.endpointError = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.setEndpointError(Self.errorMessage(for: error), for: revision)
            }
        }
    }

    @discardableResult
    private func persist(_ input: CameraInput, url: URL) -> Bool {
        guard !camera.isDeleted,
              !requiresAttachedCamera || camera.modelContext != nil else { return false }
        if camera.authenticationRequired != input.requiresAuthentication {
            camera.authenticationRequired = input.requiresAuthentication
        }
        if camera.streamURLString != url.absoluteString {
            camera.streamURLString = url.absoluteString
        }
        return true
    }

    private func setEndpointError(_ error: String, for revision: Int) {
        guard updateRevision == revision else { return }
        endpointError = error
    }

    private func usedEndpointIdentities() -> Set<String> {
        guard let context = camera.modelContext,
              let cameras = try? context.fetch(FetchDescriptor<Camera>()) else { return [] }
        return Set(cameras.compactMap { candidate in
            guard candidate.cameraID != camera.cameraID,
                  let url = candidate.playableStreamURL else { return nil }
            return Self.endpointIdentity(for: url)
        })
    }

    nonisolated private static func endpointIdentity(for url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let scheme = components.scheme?.lowercased() ?? ""
        let host = components.host?.lowercased() ?? ""
        let port = components.port ?? (scheme == "rtsp" ? 554 : 443)
        let query = (components.queryItems ?? [])
            .filter { $0.name != "user" && $0.name != "password" }
            .sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
            .map { "\($0.name)=\($0.value ?? "")" }
            .joined(separator: "&")
        return "\(scheme)|\(host)|\(port)|\(components.path)|\(query)"
    }

    nonisolated private static func resolve(
        _ candidateGroups: [[URL]],
        using endpointCheck: @escaping EndpointCheck
    ) async throws -> URL {
        var credentialsFailed = false
        for candidates in candidateGroups {
            try Task.checkCancellation()
            do {
                return try await firstAvailable(candidates, using: endpointCheck)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CameraEndpointCheck.Failure where error == .credentials {
                credentialsFailed = true
            } catch {
                continue
            }
        }
        throw credentialsFailed
            ? CameraEndpointCheck.Failure.credentials
            : CameraEndpointCheck.Failure.unavailable
    }

    nonisolated private static func firstAvailable(
        _ candidates: [URL],
        using endpointCheck: @escaping EndpointCheck
    ) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            for candidate in candidates {
                group.addTask {
                    try Task.checkCancellation()
                    try await endpointCheck(candidate)
                    try Task.checkCancellation()
                    return candidate
                }
            }
            var credentialsFailed = false
            while !group.isEmpty {
                do {
                    guard let url = try await group.next() else { break }
                    group.cancelAll()
                    return url
                } catch is CancellationError {
                    if Task.isCancelled {
                        group.cancelAll()
                        throw CancellationError()
                    }
                } catch let error as CameraEndpointCheck.Failure where error == .credentials {
                    credentialsFailed = true
                } catch {
                    continue
                }
            }
            throw credentialsFailed
                ? CameraEndpointCheck.Failure.credentials
                : CameraEndpointCheck.Failure.unavailable
        }
    }

    private static func errorMessage(for error: Error) -> String {
        (error as? CameraEndpointCheck.Failure)?.errorDescription
            ?? "Could not reach the camera. Check the address and connection."
    }
}

final class CameraEndpointCheck: NSObject, URLSessionTaskDelegate, Sendable {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func check(configuration: URLSessionConfiguration = .ephemeral) async throws {
        try Task.checkCancellation()
        if url.scheme?.lowercased() == "rtsp" {
            let endpoint = await MainActor.run { RTSPEndpointCheck(url: url) }
            try await endpoint.check()
            return
        }
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("video/x-flv", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.unavailable }
        if response.statusCode == 401 || response.statusCode == 403 { throw Failure.credentials }
        guard (200..<300).contains(response.statusCode) else { throw Failure.unavailable }
        var parser = FLVParser()
        var builder = AVCSampleBuilder()
        for try await byte in bytes {
            try Task.checkCancellation()
            do {
                for tag in try parser.append(Data([byte])) {
                    if try builder.sample(for: tag) != nil { return }
                }
            } catch {
                throw Failure.unavailable
            }
        }
        try Task.checkCancellation()
        throw Failure.unavailable
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           CameraCertificateTrust.allows(url: url, host: challenge.protectionSpace.host),
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    enum Failure: LocalizedError {
        case credentials
        case unavailable

        var errorDescription: String? {
            switch self {
            case .credentials: "Check the camera username and password."
            case .unavailable: "No compatible video stream found. Check the camera address."
            }
        }
    }
}

@MainActor
private final class RTSPEndpointCheck {
    private let ingest: RTSPIngest
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var state = PlaybackState.connecting

    init(url: URL) {
        ingest = RTSPIngest(url: url)
        ingest.retryDelay = .seconds(30)
        ingest.failureRetryDelay = .seconds(30)
        ingest.stallTimeout = 8
    }

    func check() async throws {
        try ingest.attachDisplay(displayLayer) { [weak self] state in
            self?.state = state
        }
        ingest.start()
        defer {
            ingest.stop()
            ingest.detachDisplay(displayLayer)
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(8)
        while clock.now < deadline, state == .connecting {
            try await Task.sleep(for: .milliseconds(20))
        }
        switch state {
        case .playing:
            return
        case .unauthorized:
            throw CameraEndpointCheck.Failure.credentials
        default:
            throw CameraEndpointCheck.Failure.unavailable
        }
    }
}
