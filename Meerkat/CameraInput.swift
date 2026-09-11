import Combine
import Foundation

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
        if components.path.isEmpty || components.path == "/" {
            components.path = "/flv"
        }
        var items = (components.queryItems ?? []).filter { $0.name != "user" && $0.name != "password" }
        if components.path == "/flv" {
            for (name, value) in [("port", "1935"), ("app", "bcs"), ("stream", "channel0_sub.bcs")] {
                if !items.contains(where: { $0.name == name }) {
                    items.append(URLQueryItem(name: name, value: value))
                }
            }
        }
        if requiresAuthentication {
            items.append(URLQueryItem(name: "user", value: username))
            items.append(URLQueryItem(name: "password", value: password))
        }
        components.queryItems = items.isEmpty ? nil : items
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components.user = nil
        components.password = nil
        components.fragment = nil
        return components.url
    }

    var completeStreamURL: URL? {
        guard !requiresAuthentication || (!username.isEmpty && !password.isEmpty) else { return nil }
        return streamURL
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
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        components.scheme = "https"
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
    private let debounceDuration: Duration
    private let endpointCheck: EndpointCheck
    private var updateRevision = 0
    private var updateTask: Task<Void, Never>?

    init(
        camera: Camera,
        debounceDuration: Duration = .milliseconds(700),
        endpointCheck: @escaping EndpointCheck = { url in
            try await CameraEndpointCheck(url: url).check()
        }
    ) {
        self.camera = camera
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
        guard let url = input.completeStreamURL else { return }
        persist(input, url: url)
    }

    private func scheduleUpdate() {
        updateTask?.cancel()
        updateRevision &+= 1
        let revision = updateRevision
        let input = input
        let debounceDuration = debounceDuration
        let endpointCheck = endpointCheck
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
                guard input.completeStreamURL != nil else {
                    self?.setEndpointError("Enter the camera username and password.", for: revision)
                    return
                }
                guard self?.updateRevision == revision else { return }
                self?.persist(input, url: url)

                try await endpointCheck(url)
                try Task.checkCancellation()
                guard self?.updateRevision == revision else { return }
                self?.endpointError = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.setEndpointError(Self.errorMessage(for: error), for: revision)
            }
        }
    }

    private func persist(_ input: CameraInput, url: URL) {
        if camera.authenticationRequired != input.requiresAuthentication {
            camera.authenticationRequired = input.requiresAuthentication
        }
        if camera.streamURLString != url.absoluteString {
            camera.streamURLString = url.absoluteString
        }
    }

    private func setEndpointError(_ error: String, for revision: Int) {
        guard updateRevision == revision else { return }
        endpointError = error
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
        var signature: [UInt8] = []
        for try await byte in bytes {
            try Task.checkCancellation()
            signature.append(byte)
            if signature.count == 3 { break }
        }
        guard signature == [0x46, 0x4c, 0x56] else { throw Failure.unavailable }
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
            case .unavailable: "No FLV stream found. Check the camera address."
            }
        }
    }
}
