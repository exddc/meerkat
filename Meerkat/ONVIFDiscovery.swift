import CryptoKit
import Foundation

final class ONVIFDiscovery: NSObject, URLSessionTaskDelegate, Sendable {
    typealias Failure = CameraEndpointCheck.Failure

    static let requestTimeout: TimeInterval = 4
    static let responseLimit = 1 << 20
    static let profileLimit = 4

    let deviceServiceURLs: [URL]
    private let credentials: (user: String, password: String)?
    private let timeout: Duration

    init(
        deviceServiceURLs: [URL],
        credentials: (user: String, password: String)?,
        timeout: Duration = .seconds(12)
    ) {
        self.deviceServiceURLs = deviceServiceURLs
        self.credentials = credentials
        self.timeout = timeout
    }

    func streamURIs(configuration: URLSessionConfiguration = .ephemeral) async throws -> [String] {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.requestTimeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask { try await self.discover(using: session) }
            group.addTask {
                try await Task.sleep(for: self.timeout)
                throw Failure.unavailable
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    static func document(from data: Data, response: URLResponse) throws -> XMLDocument {
        guard let response = response as? HTTPURLResponse else { throw Failure.unavailable }
        let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        let faultCodes = Set((document?.strings(at: "Subcode/Value") ?? []).compactMap {
            $0.split(separator: ":").last.map(String.init)
        })
        if [401, 403].contains(response.statusCode)
            || !faultCodes.isDisjoint(with: ["NotAuthorized", "FailedAuthentication"]) {
            throw Failure.credentials
        }
        guard (200..<300).contains(response.statusCode), let document, document.nodes(at: "Fault").isEmpty else {
            throw Failure.unavailable
        }
        return document
    }

    private func discover(using session: URLSession) async throws -> [String] {
        let (deviceURL, clockOffset) = try await deviceService(using: session)
        let capabilities = try await send(.capabilities, to: deviceURL, using: session, clockOffset: clockOffset)
        guard let address = capabilities.strings(at: "Media/XAddr").first,
              let mediaURL = Self.serviceURL(address, on: deviceURL) else { throw Failure.unavailable }
        let profiles = try await send(.profiles, to: mediaURL, using: session, clockOffset: clockOffset)
        let tokens = profiles.nodes(at: "Profiles")
            .filter { $0.strings(at: "VideoEncoderConfiguration/Encoding").first == "H264" }
            .compactMap { ($0 as? XMLElement)?.attribute(forName: "token")?.stringValue }
            .prefix(Self.profileLimit)
        return try await withThrowingTaskGroup(of: (Int, String?).self) { group in
            for (index, token) in tokens.enumerated() {
                group.addTask {
                    let response = try? await self.send(
                        .streamURI(token), to: mediaURL, using: session, clockOffset: clockOffset
                    )
                    return (index, response?.strings(at: "MediaUri/Uri").first)
                }
            }
            var uris = [Int: String]()
            for try await (index, uri) in group {
                uris[index] = uri
            }
            try Task.checkCancellation()
            return uris.sorted { $0.key < $1.key }.map(\.value)
        }
    }

    private func deviceService(using session: URLSession) async throws -> (URL, TimeInterval) {
        try await withThrowingTaskGroup(of: Result<(URL, TimeInterval), Failure>.self) { group in
            for url in deviceServiceURLs {
                group.addTask {
                    do {
                        return .success((url, try await self.clockOffset(at: url, using: session)))
                    } catch {
                        return .failure(error as? Failure ?? .unavailable)
                    }
                }
            }
            var failure = Failure.unavailable
            for try await result in group {
                switch result {
                case .success(let service):
                    group.cancelAll()
                    return service
                case .failure(let error):
                    if error == .credentials { failure = error }
                }
            }
            try Task.checkCancellation()
            throw failure
        }
    }

    private func clockOffset(at url: URL, using session: URLSession) async throws -> TimeInterval {
        let response: XMLDocument
        do {
            response = try await send(.systemDateAndTime, to: url, using: session, clockOffset: nil)
        } catch Failure.credentials where credentials != nil {
            response = try await send(.systemDateAndTime, to: url, using: session, clockOffset: 0)
        }
        guard !response.nodes(at: "GetSystemDateAndTimeResponse").isEmpty else { throw Failure.unavailable }
        return Self.clockOffset(from: response)
    }

    private func send(
        _ operation: Operation,
        to url: URL,
        using session: URLSession,
        clockOffset: TimeInterval?
    ) async throws -> XMLDocument {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/soap+xml; charset=utf-8; action=\"\(operation.action)\"",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Data(envelope(operation, clockOffset: clockOffset).utf8)
        var data = Data()
        let response: URLResponse
        do {
            let (bytes, bytesResponse) = try await session.bytes(for: request)
            for try await byte in bytes {
                guard data.count < Self.responseLimit else { throw Failure.unavailable }
                data.append(byte)
            }
            response = bytesResponse
        } catch {
            try Task.checkCancellation()
            throw Failure.unavailable
        }
        return try Self.document(from: data, response: response)
    }

    private func envelope(_ operation: Operation, clockOffset: TimeInterval?) -> String {
        var header = ""
        if let credentials, let clockOffset {
            let nonce = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
            let created = Date(timeIntervalSinceNow: clockOffset).formatted(.iso8601)
            let digest = Data(Insecure.SHA1.hash(data: nonce + Data(created.utf8) + Data(credentials.password.utf8)))
            header = """
                <s:Header><wsse:Security s:mustUnderstand="1" \
                xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" \
                xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">\
                <wsse:UsernameToken><wsse:Username>\(Self.escaped(credentials.user))</wsse:Username>\
                <wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\
                \(digest.base64EncodedString())</wsse:Password>\
                <wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\
                \(nonce.base64EncodedString())</wsse:Nonce>\
                <wsu:Created>\(created)</wsu:Created></wsse:UsernameToken></wsse:Security></s:Header>
                """
        }
        return """
            <?xml version="1.0" encoding="UTF-8"?>\
            <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">\
            \(header)<s:Body>\(operation.body)</s:Body></s:Envelope>
            """
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPDigest:
            guard let credentials, challenge.previousFailureCount == 0 else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(
                .useCredential,
                URLCredential(user: credentials.user, password: credentials.password, persistence: .none)
            )
        case NSURLAuthenticationMethodServerTrust:
            completionHandler(.performDefaultHandling, nil)
        default:
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private static func serviceURL(_ address: String, on deviceURL: URL) -> URL? {
        guard let advertised = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              !advertised.percentEncodedPath.isEmpty,
              var components = URLComponents(url: deviceURL, resolvingAgainstBaseURL: false) else { return nil }
        components.percentEncodedPath = advertised.percentEncodedPath
        components.percentEncodedQuery = advertised.percentEncodedQuery
        return components.url
    }

    private static func clockOffset(from response: XMLDocument) -> TimeInterval {
        let values = ["Date/Year", "Date/Month", "Date/Day", "Time/Hour", "Time/Minute", "Time/Second"]
            .compactMap { response.strings(at: "UTCDateTime/\($0)").first.flatMap { Int($0) } }
        guard values.count == 6 else { return 0 }
        let components = DateComponents(
            calendar: Calendar(identifier: .gregorian), timeZone: .gmt,
            year: values[0], month: values[1], day: values[2],
            hour: values[3], minute: values[4], second: values[5]
        )
        return components.date?.timeIntervalSinceNow ?? 0
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private enum Operation {
        case systemDateAndTime
        case capabilities
        case profiles
        case streamURI(String)

        var action: String { "\(namespace)/\(name)" }
        var body: String { "<\(name) xmlns=\"\(namespace)\">\(content)</\(name)>" }

        private var namespace: String {
            switch self {
            case .systemDateAndTime, .capabilities: "http://www.onvif.org/ver10/device/wsdl"
            case .profiles, .streamURI: "http://www.onvif.org/ver10/media/wsdl"
            }
        }

        private var name: String {
            switch self {
            case .systemDateAndTime: "GetSystemDateAndTime"
            case .capabilities: "GetCapabilities"
            case .profiles: "GetProfiles"
            case .streamURI: "GetStreamUri"
            }
        }

        private var content: String {
            switch self {
            case .systemDateAndTime, .profiles:
                ""
            case .capabilities:
                "<Category>Media</Category>"
            case .streamURI(let token):
                """
                <StreamSetup><Stream xmlns="http://www.onvif.org/ver10/schema">RTP-Unicast</Stream>\
                <Transport xmlns="http://www.onvif.org/ver10/schema"><Protocol>RTSP</Protocol></Transport>\
                </StreamSetup><ProfileToken>\(ONVIFDiscovery.escaped(token))</ProfileToken>
                """
            }
        }
    }
}

private extension XMLNode {
    func nodes(at path: String) -> [XMLNode] {
        let steps = path.split(separator: "/").map { "*[local-name()='\($0)']" }
        return (try? nodes(forXPath: ".//" + steps.joined(separator: "/"))) ?? []
    }

    func strings(at path: String) -> [String] {
        nodes(at: path).compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
