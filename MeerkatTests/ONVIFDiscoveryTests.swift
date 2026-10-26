import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import Meerkat

struct ONVIFDiscoveryTests {
    private let configuration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ONVIFCameraProtocol.self]
        return configuration
    }()

    private func discovery(
        _ hosts: [String],
        password: String = "secret",
        timeout: Duration = .seconds(12)
    ) -> ONVIFDiscovery {
        ONVIFDiscovery(
            deviceServiceURLs: hosts.map { URL(string: "http://\($0)/onvif/device_service")! },
            credentials: ("admin", password),
            timeout: timeout
        )
    }

    @Test func discoversAuthenticatedH264StreamURIs() async throws {
        let uris = try await discovery(["closed.test:2020", "camera.test"]).streamURIs(configuration: configuration)

        #expect(uris == [
            "rtsp://10.0.0.99:554/Streaming/Channels/101?transportmode=unicast&profile=101",
            "rtsp://10.0.0.99:554/Streaming/Channels/102?transportmode=unicast&profile=102",
        ])
        let requests = ONVIFCameraProtocol.requests(for: "camera.test")
        let mediaRequests = requests.filter { $0.contains("GetProfiles") || $0.contains("GetStreamUri") }
        #expect(mediaRequests.allSatisfy { $0.hasPrefix("80 /onvif/Media ") })
        #expect(Set(requests.filter { $0.contains("GetStreamUri") }) == [
            "80 /onvif/Media GetStreamUri 101",
            "80 /onvif/Media GetStreamUri fault",
            "80 /onvif/Media GetStreamUri 102",
        ])
    }

    @Test func authenticatesClockRequestWhenCameraRequiresIt() async throws {
        let uris = try await discovery(["locked.test"]).streamURIs(configuration: configuration)

        #expect(uris.count == 2)
    }

    @Test func proceedsWithoutCameraClock() async throws {
        let uris = try await discovery(["noclock.test"]).streamURIs(configuration: configuration)

        #expect(uris.count == 2)
    }

    @Test func limitsRequestedProfiles() async throws {
        let uris = try await discovery(["nvr.test"]).streamURIs(configuration: configuration)

        #expect(uris.count == ONVIFDiscovery.profileLimit)
        #expect(ONVIFCameraProtocol.requests(for: "nvr.test").filter { $0.contains("GetStreamUri") }.count
            == ONVIFDiscovery.profileLimit)
    }

    @Test(arguments: ["wrong.test", "locked.test"])
    func reportsWrongCredentials(host: String) async throws {
        await #expect(throws: CameraEndpointCheck.Failure.credentials) {
            try await discovery([host], password: "wrong").streamURIs(configuration: configuration)
        }
    }

    @Test func reportsUnavailableWithoutONVIFService() async throws {
        await #expect(throws: CameraEndpointCheck.Failure.unavailable) {
            try await discovery(["missing.test"]).streamURIs(configuration: configuration)
        }
    }

    @Test func boundsStalledDiscovery() async throws {
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: CameraEndpointCheck.Failure.unavailable) {
            try await discovery(["stall.test"], timeout: .milliseconds(100)).streamURIs(configuration: configuration)
        }
        #expect(clock.now - start < .seconds(2))
    }

    @Test func cancelsStalledDiscovery() async throws {
        let onvif = discovery(["stall.test"])
        let configuration = configuration
        let task = Task { try await onvif.streamURIs(configuration: configuration) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func classifiesResponses() throws {
        func classify(_ status: Int, _ body: String) -> CameraEndpointCheck.Failure? {
            let response = HTTPURLResponse(
                url: URL(string: "http://camera.test")!, statusCode: status, httpVersion: nil, headerFields: nil
            )!
            do {
                _ = try ONVIFDiscovery.document(from: Data(body.utf8), response: response)
                return nil
            } catch {
                return error as? CameraEndpointCheck.Failure
            }
        }

        #expect(classify(401, "") == .credentials)
        #expect(classify(400, ONVIFCameraProtocol.envelope(ONVIFCameraProtocol.notAuthorized)) == .credentials)
        #expect(classify(500, ONVIFCameraProtocol.envelope(
            "<s:Fault><s:Code><s:Subcode><s:Value>wsse:FailedAuthentication</s:Value></s:Subcode></s:Code></s:Fault>"
        )) == .credentials)
        #expect(classify(500, ONVIFCameraProtocol.envelope(
            "<s:Fault><s:Code><s:Value>s:Receiver</s:Value></s:Code><s:Reason>NotAuthorized</s:Reason></s:Fault>"
        )) == .unavailable)
        #expect(classify(200, "<html>") == .unavailable)
        #expect(classify(200, ONVIFCameraProtocol.envelope("<tds:GetCapabilitiesResponse/>")) == nil)
    }

    @Test func answersOnlyFirstHTTPDigestChallenge() throws {
        let discovery = ONVIFDiscovery(deviceServiceURLs: [], credentials: ("admin", "secret"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "http://camera.test/onvif/device_service")!)

        func respond(to method: String, failures: Int) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            let space = URLProtectionSpace(
                host: "camera.test", port: 80, protocol: "http", realm: "ONVIF", authenticationMethod: method
            )
            let challenge = URLAuthenticationChallenge(
                protectionSpace: space, proposedCredential: nil, previousFailureCount: failures,
                failureResponse: nil, error: nil, sender: ChallengeSender()
            )
            let result = Mutex<(URLSession.AuthChallengeDisposition, URLCredential?)>((.useCredential, nil))
            discovery.urlSession(session, task: task, didReceive: challenge) { disposition, credential in
                result.withLock { $0 = (disposition, credential) }
            }
            return result.withLock { $0 }
        }

        let digest = respond(to: NSURLAuthenticationMethodHTTPDigest, failures: 0)
        #expect(digest.0 == .useCredential)
        #expect(digest.1?.user == "admin")
        #expect(digest.1?.password == "secret")
        let retry = respond(to: NSURLAuthenticationMethodHTTPDigest, failures: 1)
        #expect(retry.0 == .performDefaultHandling)
        #expect(retry.1 == nil)
        #expect(respond(to: NSURLAuthenticationMethodHTTPBasic, failures: 0).0 == .cancelAuthenticationChallenge)
    }
}

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

private final class ONVIFCameraProtocol: URLProtocol, @unchecked Sendable {
    private static let recorded = Mutex<[String: [String]]>([:])
    private static let skewedClock = Date(timeIntervalSince1970: 1_577_934_245)
    private static let hosts: Set = ["camera.test", "wrong.test", "locked.test", "noclock.test", "nvr.test"]
    static let notAuthorized = """
        <s:Fault><s:Code><s:Value>s:Sender</s:Value><s:Subcode><s:Value>ter:NotAuthorized</s:Value>\
        </s:Subcode></s:Code><s:Reason><s:Text>Sender not Authorized</s:Text></s:Reason></s:Fault>
        """

    static func requests(for host: String) -> [String] {
        recorded.withLock { $0[host] ?? [] }
    }

    static func envelope(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>\
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" \
        xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:trt="http://www.onvif.org/ver10/media/wsdl" \
        xmlns:tt="http://www.onvif.org/ver10/schema" xmlns:ter="http://www.onvif.org/ver10/error" \
        xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">\
        <s:Body>\(body)</s:Body></s:Envelope>
        """
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let host = url.host ?? ""
        guard host != "stall.test" else { return }
        guard Self.hosts.contains(host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let document = try? XMLDocument(data: requestBody())
        let operation = ["GetSystemDateAndTime", "GetCapabilities", "GetProfiles", "GetStreamUri"]
            .first { document?.value(at: "Body/\($0)") != nil } ?? ""
        let token = document?.value(at: "ProfileToken")
        Self.recorded.withLock {
            $0[host, default: []].append(
                ["\(url.port ?? 80)", url.path, operation, token].compactMap { $0 }.joined(separator: " ")
            )
        }
        let clock = ["camera.test", "wrong.test"].contains(host) ? Self.skewedClock : Date()
        let authorized = document.map { isAuthorized($0, clock: clock) } ?? false

        switch operation {
        case "GetSystemDateAndTime" where host == "noclock.test":
            respond(200, "<tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime/></tds:GetSystemDateAndTimeResponse>")
        case "GetSystemDateAndTime" where host != "locked.test" || authorized:
            respond(200, Self.systemDateAndTime(clock))
        case _ where !authorized && host == "locked.test":
            respond(401, nil)
        case _ where !authorized:
            respond(400, Self.notAuthorized)
        case "GetCapabilities":
            respond(200, """
                <tds:GetCapabilitiesResponse><tds:Capabilities><tt:Media>\
                <tt:XAddr>http://10.0.0.99:8999/onvif/Media</tt:XAddr>\
                </tt:Media></tds:Capabilities></tds:GetCapabilitiesResponse>
                """)
        case "GetProfiles" where url.path == "/onvif/Media":
            let profiles: [(String, String?)] = host == "nvr.test"
                ? (1...6).map { ("\($0)", "H264") }
                : [("101", "H264"), ("fault", "H264"), ("102", "H264"), ("103", "H265"), ("audio", nil)]
            respond(200, "<trt:GetProfilesResponse>" + profiles.map { token, encoding in
                let video = encoding.map {
                    "<tt:VideoEncoderConfiguration token=\"video\"><tt:Encoding>\($0)</tt:Encoding></tt:VideoEncoderConfiguration>"
                } ?? ""
                return "<trt:Profiles token=\"\(token)\">\(video)</trt:Profiles>"
            }.joined() + "</trt:GetProfilesResponse>")
        case "GetStreamUri" where url.path == "/onvif/Media" && token != "fault":
            let token = token ?? ""
            respond(200, """
                <trt:GetStreamUriResponse><trt:MediaUri><tt:Uri>\
                rtsp://10.0.0.99:554/Streaming/Channels/\(token)?transportmode=unicast&amp;profile=\(token)\
                </tt:Uri></trt:MediaUri></trt:GetStreamUriResponse>
                """)
        default:
            respond(400, "<s:Fault><s:Code><s:Value>s:Sender</s:Value></s:Code></s:Fault>")
        }
    }

    override func stopLoading() {}

    private static func systemDateAndTime(_ date: Date) -> String {
        let utc = Calendar(identifier: .gregorian).dateComponents(in: .gmt, from: date)
        return """
            <tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime><tt:UTCDateTime>\
            <tt:Time><tt:Hour>\(utc.hour!)</tt:Hour><tt:Minute>\(utc.minute!)</tt:Minute>\
            <tt:Second>\(utc.second!)</tt:Second></tt:Time>\
            <tt:Date><tt:Year>\(utc.year!)</tt:Year><tt:Month>\(utc.month!)</tt:Month><tt:Day>\(utc.day!)</tt:Day>\
            </tt:Date></tt:UTCDateTime></tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse>
            """
    }

    private func isAuthorized(_ document: XMLDocument, clock: Date) -> Bool {
        guard let user = document.value(at: "UsernameToken/Username"),
              let digest = document.value(at: "UsernameToken/Password"),
              let nonce = document.value(at: "UsernameToken/Nonce").flatMap({ Data(base64Encoded: $0) }),
              let created = document.value(at: "UsernameToken/Created"),
              let createdDate = try? Date(created, strategy: .iso8601),
              abs(createdDate.timeIntervalSince(clock)) < 60 else { return false }
        let expected = Data(Insecure.SHA1.hash(data: nonce + Data(created.utf8) + Data("secret".utf8)))
        return user == "admin" && digest == expected.base64EncodedString()
    }

    private func respond(_ status: Int, _ body: String?) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/soap+xml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body {
            client?.urlProtocol(self, didLoad: Data(Self.envelope(body).utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private extension XMLDocument {
    func value(at path: String) -> String? {
        let xpath = "//" + path.split(separator: "/").map { "*[local-name()='\($0)']" }.joined(separator: "/")
        return (try? nodes(forXPath: xpath))?.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
