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
