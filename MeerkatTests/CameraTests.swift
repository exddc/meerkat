import Foundation
import Testing
@testable import Meerkat

struct CameraTests {
    @Test
    func preservesLiteralBangInStreamPassword() {
        let camera = Camera(
            name: "Front Door",
            streamURLString: "https://camera.test/flv?user=viewer&password=secret!"
        )

        #expect(camera.streamURL.absoluteString.contains("password=secret!"))
        #expect(!camera.streamURL.absoluteString.contains("%21"))
    }

    @Test
    func playableStreamURLRequiresHost() {
        let empty = Camera(name: "", streamURLString: "")
        let incomplete = Camera(name: "", streamURLString: "https://")
        let ready = Camera(
            name: "Garten",
            streamURLString: "https://192.0.2.10/flv?port=1935"
        )

        #expect(empty.playableStreamURL == nil)
        #expect(incomplete.playableStreamURL == nil)
        #expect(ready.playableStreamURL?.host == "192.0.2.10")
    }

    @Test
    func rejectsNonHTTPSPlayback() {
        for url in ["http://192.168.1.2/flv", "rtsp://192.168.1.2/live", "file:///tmp/stream.flv"] {
            #expect(Camera(name: "", streamURLString: url).playableStreamURL == nil)
        }
    }

}

struct CameraInputTests {
    @Test func expandsBareAddressWithReolinkDefaults() throws {
        let input = CameraInput(" 192.168.1.25:8443 ")
        let url = try #require(input.streamURL)
        #expect(url.scheme == "https")
        #expect(url.host == "192.168.1.25")
        #expect(url.port == 8443)
        #expect(url.path == "/flv")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "stream", value: "channel0_sub.bcs")))
        #expect(items.contains(URLQueryItem(name: "app", value: "bcs")))
        #expect(input.requiresAuthentication)
    }

    @Test func importsCredentialsAndPreservesStreamOptions() throws {
        let input = CameraInput("https://192.168.1.25/flv?stream=channel2_sub.bcs&user=viewer&password=a%26b%23c!")
        #expect(input.username == "viewer")
        #expect(input.password == "a&b#c!")
        #expect(!input.address.contains("password"))
        #expect(!input.address.contains("user="))
        let url = try #require(input.streamURL)
        #expect(url.absoluteString.contains("password=a%26b%23c!"))
        #expect(url.absoluteString.contains("stream=channel2_sub.bcs"))
    }

    @Test func restoresEditingAddressFromPersistedDefaultReolinkURL() {
        let input = CameraInput(
            playbackURLString: "https://192.168.1.25:8443/flv?port=1935&app=bcs&stream=channel0_sub.bcs&user=viewer&password=secret",
            authenticationRequired: true
        )

        #expect(input.address == "192.168.1.25:8443")
        #expect(input.username == "viewer")
        #expect(input.password == "secret")
    }

    @Test func preservesCustomURLWhenRestoringEditingAddress() {
        let url = "https://camera.test/custom?channel=2"
        let input = CameraInput(playbackURLString: url, authenticationRequired: false)

        #expect(input.address == url)
    }

    @Test func percentEncodesPlusInCredentials() throws {
        var input = CameraInput("192.168.1.25")
        input.username = "viewer+admin"
        input.password = "secret+value"

        let url = try #require(input.streamURL)
        #expect(url.absoluteString.contains("user=viewer%2Badmin"))
        #expect(url.absoluteString.contains("password=secret%2Bvalue"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "user", value: "viewer+admin")))
        #expect(items.contains(URLQueryItem(name: "password", value: "secret+value")))
    }

    @Test func authToggleRemovesCredentialsAndPasteReactivatesIt() throws {
        var input = CameraInput("https://viewer:secret@192.168.1.25/flv")
        #expect(input.username == "viewer")
        #expect(input.password == "secret")
        #expect(!input.address.contains("@"))
        input.requiresAuthentication = false
        let url = try #require(input.streamURL)
        #expect(!url.absoluteString.contains("user="))
        #expect(!url.absoluteString.contains("password="))
        input.address = "https://192.168.1.26/flv?user=admin&password=new!"
        input.importCredentials()
        #expect(input.requiresAuthentication)
        #expect(input.username == "admin")
        #expect(input.password == "new!")
    }

    @Test func preservesExplicitEndpointsAndIPv6() {
        var input = CameraInput("https://camera.test/custom?channel=2")
        input.requiresAuthentication = false
        #expect(input.streamURL?.absoluteString == "https://camera.test/custom?channel=2")
        #expect(CameraInput("[fd00::1]:8443").streamURL?.path == "/flv")
    }

    @Test func rejectsInvalidAddresses() {
        for input in ["", "https://", "http://192.168.1.2", "rtsp://camera/live", "not an address", "192.168.1.2:99999"] {
            #expect(CameraInput(input).streamURL == nil)
        }
    }

    @Test func normalizesSchemeForPlayback() {
        let input = CameraInput("HTTPS://192.168.1.25")
        #expect(input.streamURL?.scheme == "https")
    }

    @Test func requiresCompleteCredentialsForPlaybackUpdate() {
        var input = CameraInput("192.168.1.25")
        input.username = "viewer"
        #expect(input.completeStreamURL == nil)
        input.password = "secret"
        #expect(input.completeStreamURL != nil)
    }

    @Test func cancelsStalledEndpointProbe() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CameraCheckProtocol.self]
        let task = Task {
            try await CameraEndpointCheck(url: URL(string: "https://fixture.test/stall")!).check(configuration: configuration)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            try await task.value
            Issue.record("Cancelled probe completed successfully")
        } catch {
            #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
    }

    @Test func endpointProbeValidatesStreamBytesAndStatus() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CameraCheckProtocol.self]
        try await CameraEndpointCheck(url: URL(string: "https://fixture.test/flv")!).check(configuration: configuration)
        for path in ["html", "missing", "unauthorized", "empty"] {
            do {
                try await CameraEndpointCheck(url: URL(string: "https://fixture.test/\(path)")!).check(configuration: configuration)
                Issue.record("Accepted invalid endpoint: \(path)")
            } catch let error as CameraEndpointCheck.Failure {
                if path == "unauthorized" {
                    #expect(error == .credentials)
                } else {
                    #expect(error == .unavailable)
                }
            }
        }
    }
}

@MainActor
struct CameraConfigurationEditorTests {
    @Test func persistsAndValidatesOnlyCompleteCredentials() async throws {
        let camera = Camera(name: "Front Door", streamURLString: "https://old.test/live")
        camera.authenticationRequired = false
        let probes = EndpointProbeRecorder()
        let editor = CameraConfigurationEditor(
            camera: camera,
            debounceDuration: .zero,
            endpointCheck: { try await probes.check($0) }
        )

        var input = editor.input
        input.address = "new.test"
        input.requiresAuthentication = true
        input.username = "viewer"
        input.password = ""
        editor.input = input
        try await waitUntil { editor.endpointError != nil }

        #expect(camera.streamURLString == "https://old.test/live")
        #expect(await probes.startedURLs.isEmpty)
        #expect(editor.endpointError == "Enter the camera username and password.")

        input.password = "secret"
        editor.input = input
        let firstURL = try #require(input.completeStreamURL)
        try await waitUntil { await probes.hasStarted(firstURL) }
        #expect(camera.streamURLString == firstURL.absoluteString)
        await probes.succeed(firstURL)

        input.username = "admin"
        editor.input = input
        let secondURL = try #require(input.completeStreamURL)
        try await waitUntil { await probes.hasStarted(secondURL) }
        await probes.succeed(secondURL)

        input.password = "new-secret"
        editor.input = input
        let thirdURL = try #require(input.completeStreamURL)
        try await waitUntil { await probes.hasStarted(thirdURL) }
        await probes.succeed(thirdURL)
        #expect(await probes.startedURLs == [firstURL, secondURL, thirdURL])
    }

    @Test func flushesCompletePendingConfigurationWithoutValidation() async throws {
        let camera = Camera(name: "Front Door", streamURLString: "https://old.test/live")
        camera.authenticationRequired = false
        let probes = EndpointProbeRecorder()
        let editor = CameraConfigurationEditor(
            camera: camera,
            debounceDuration: .seconds(30),
            endpointCheck: { try await probes.check($0) }
        )

        var input = editor.input
        input.address = "https://current.test/live"
        editor.input = input
        let currentURL = try #require(input.completeStreamURL)
        editor.flush()
        try await Task.sleep(for: .milliseconds(20))

        #expect(camera.streamURLString == currentURL.absoluteString)
        #expect(await probes.startedURLs.isEmpty)
    }

    @Test func debouncesPlaybackConfigurationUpdates() async throws {
        let camera = Camera(name: "Front Door", streamURLString: "https://old.test/live")
        camera.authenticationRequired = false
        let probes = EndpointProbeRecorder()
        let editor = CameraConfigurationEditor(
            camera: camera,
            debounceDuration: .milliseconds(50),
            endpointCheck: { try await probes.check($0) }
        )

        var input = editor.input
        input.address = "https://first.test/live"
        editor.input = input
        input.address = "https://current.test/live"
        editor.input = input
        let currentURL = try #require(input.completeStreamURL)

        try await Task.sleep(for: .milliseconds(20))
        #expect(camera.streamURLString == "https://old.test/live")
        #expect(await probes.startedURLs.isEmpty)

        try await waitUntil { await probes.hasStarted(currentURL) }
        #expect(camera.streamURLString == currentURL.absoluteString)
        #expect(await probes.startedURLs == [currentURL])
        await probes.succeed(currentURL)
    }

    @Test func successfulValidationClearsErrorAndStaleFailureCannotRestoreIt() async throws {
        let camera = Camera(name: "Front Door", streamURLString: "https://initial.test/live")
        camera.authenticationRequired = false
        let probes = EndpointProbeRecorder()
        let editor = CameraConfigurationEditor(
            camera: camera,
            debounceDuration: .zero,
            endpointCheck: { try await probes.check($0) }
        )

        var input = editor.input
        input.address = "https://failed.test/live"
        editor.input = input
        let failedURL = try #require(input.completeStreamURL)
        try await waitUntil { await probes.hasStarted(failedURL) }
        await probes.fail(failedURL)
        try await waitUntil { editor.endpointError != nil }

        input.address = "https://stale.test/live"
        editor.input = input
        let staleURL = try #require(input.completeStreamURL)
        try await waitUntil { await probes.hasStarted(staleURL) }

        input.address = "https://current.test/live"
        editor.input = input
        let currentURL = try #require(input.completeStreamURL)
        try await waitUntil { await probes.hasStarted(currentURL) }
        await probes.succeed(currentURL)
        try await waitUntil { editor.endpointError == nil }

        await probes.fail(staleURL)
        try await Task.sleep(for: .milliseconds(20))

        #expect(editor.endpointError == nil)
        #expect(camera.streamURLString == currentURL.absoluteString)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for asynchronous editor state")
    }
}

private actor EndpointProbeRecorder {
    private var continuations: [URL: CheckedContinuation<Void, any Error>] = [:]
    private(set) var startedURLs: [URL] = []

    func check(_ url: URL) async throws {
        startedURLs.append(url)
        try await withCheckedThrowingContinuation { continuation in
            continuations[url] = continuation
        }
    }

    func hasStarted(_ url: URL) -> Bool {
        continuations[url] != nil
    }

    func succeed(_ url: URL) {
        continuations.removeValue(forKey: url)?.resume()
    }

    func fail(_ url: URL) {
        continuations.removeValue(forKey: url)?.resume(throwing: CameraEndpointCheck.Failure.unavailable)
    }
}

private final class CameraCheckProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let status = url.path == "/missing" ? 404 : url.path == "/unauthorized" ? 401 : 200
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path != "/empty" && url.path != "/stall" {
            let bytes = url.path == "/flv" ? [UInt8]("FLV".utf8) : [UInt8]("<html>".utf8)
            for byte in bytes {
                client?.urlProtocol(self, didLoad: Data([byte]))
            }
            if url.path == "/flv" {
                client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 64 * 1024))
            }
        }
        if url.path != "/flv" && url.path != "/stall" {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
