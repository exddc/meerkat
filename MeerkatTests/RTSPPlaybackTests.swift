import AVFoundation
import Foundation
import Testing
@testable import Meerkat

struct RTSPPlaybackTests {
    @MainActor
    @Test func invalidSavedPortFailsWithoutTrapping() throws {
        let ingest = RTSPIngest(url: URL(string: "rtsp://127.0.0.1:99999/live0")!)
        let display = AVSampleBufferDisplayLayer()
        var state = PlaybackState.connecting
        try ingest.attachDisplay(display) { state = $0 }
        defer { ingest.stop() }
        ingest.start()
        #expect(state == .unsupported)
    }

    @Test func digestMatchesRFC2617VectorAndIncrementsNonceCount() throws {
        var auth = try #require(RTSPAuthentication(
            challenge: #"Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41""#,
            user: "Mufasa", password: "Circle Of Life", cnonce: "0a4f113b"
        ))
        let header = auth.authorization(method: "GET", uri: "/dir/index.html")
        #expect(header.contains(#"response="6629fae49393a05397450978507c4ef1""#))
        #expect(header.contains("nc=00000001"))
        #expect(auth.authorization(method: "SETUP", uri: "/trackID=0").contains("nc=00000002"))
    }

    @Test func rejectsUnsupportedDigestChallenges() {
        for challenge in [#"Digest realm="camera""#, #"Digest realm="camera", nonce="n", qop="auth-int""#,
                          #"Digest realm="camera", nonce="n", algorithm=SHA-256"#] {
            #expect(RTSPAuthentication(challenge: challenge, user: "admin", password: "test") == nil)
        }
    }

    @Test func parserRejectsOversizedContentLengthWithoutOverflow() {
        var parser = RTSPMessageParser()
        #expect(throws: RTSPError.self) {
            try parser.append(Data("RTSP/1.0 200 OK\r\nContent-Length: \(Int.max)\r\n\r\n".utf8))
        }
    }

    private let sps = Data([0x67, 0x42, 0xc0, 0x16, 0xd9, 0, 0xa0, 0x2f, 0xf9, 0x70, 0x11,
                            0, 0, 3, 0, 1, 0, 0, 3, 0, 0x14, 0x0f, 0x16, 0x2e, 0x48])
    private let pps = Data([0x68, 0xcb, 0x83, 0xcb, 0x20])

    @Test func parsesSplitResponsesAndInterleavedPackets() throws {
        let body = Data("v=0\r\n".utf8)
        let response = Data("RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
        let packet = Data([0x80, 0xe0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0x65])
        let interleaved = Data([0x24, 0, 0, UInt8(packet.count)]) + packet
        let bytes = response + interleaved

        for split in 0...bytes.count {
            var parser = RTSPMessageParser()
            let events = try parser.append(Data(bytes.prefix(split)))
                + parser.append(Data(bytes.dropFirst(split)))
            #expect(events == [
                .response(RTSPResponse(statusCode: 200, headers: [
                    "cseq": "1", "content-length": String(body.count),
                ], body: body)),
                .interleaved(channel: 0, packet: packet),
            ])
        }
    }

    @Test func parsesNegotiatedInterleavedChannels() throws {
        let transport = try #require(RTSPInterleavedTransport(
            header: "RTP/AVP;unicast;client_port=5000-5001, RTP/AVP/TCP;unicast;interleaved=4-5"
        ))

        #expect(transport.rtpChannel == 4)
        #expect(transport.rtcpChannel == 5)
        #expect(RTSPInterleavedTransport(header: "RTP/AVP/TCP;unicast") == nil)
    }

    @Test func classifiesTransientAndUnsupportedFailures() {
        #expect(RTSPError.invalidMessage.playbackState == .reconnecting)
        #expect(RTSPError.invalidRTP.playbackState == .reconnecting)
        #expect(RTSPError.invalidSDP.playbackState == .unsupported)
        #expect(RTSPError.unsupportedPacketization.playbackState == .unsupported)
    }

    @Test func depacketizesSingleAndFragmentedNALUnits() throws {
        var depacketizer = RTPH264Depacketizer()
        let single = rtp(sequence: 1, timestamp: 90, marker: true, payload: Data([0x41, 1, 2]))
        #expect(try depacketizer.append(single) == RTPH264Frame(
            timestamp: 90,
            nalUnits: [Data([0x41, 1, 2])]
        ))

        let first = rtp(sequence: 2, timestamp: 180, marker: false, payload: Data([0x7c, 0x85, 3, 4]))
        let last = rtp(sequence: 3, timestamp: 180, marker: true, payload: Data([0x7c, 0x45, 5, 6]))
        #expect(try depacketizer.append(first) == nil)
        #expect(try depacketizer.append(last) == RTPH264Frame(
            timestamp: 180,
            nalUnits: [Data([0x65, 3, 4, 5, 6])]
        ))
    }

    @Test func buildsSamplesFromSDPParameterSetsAndRTPFrames() throws {
        var builder = RTPH264SampleBuilder()
        builder.setParameterSets(sps: sps, pps: pps)

        let sample = try #require(try builder.sample(for: RTPH264Frame(
            timestamp: 9_000,
            nalUnits: [Data([0x65, 0x88])]
        )))

        #expect(sample.isSyncSample)
        #expect(CMSampleBufferGetDecodeTimeStamp(sample) == CMTime(value: 100, timescale: 1000))
        #expect(CMSampleBufferGetFormatDescription(sample) != nil)
    }

    private func rtp(
        sequence: UInt16,
        timestamp: UInt32,
        marker: Bool,
        payload: Data
    ) -> Data {
        Data([
            0x80, marker ? 0xe0 : 0x60,
            UInt8(sequence >> 8), UInt8(sequence & 0xff),
            UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 0xff),
            UInt8((timestamp >> 8) & 0xff), UInt8(timestamp & 0xff),
            0, 0, 0, 1,
        ]) + payload
    }
}

@MainActor
@Suite(.enabled(
    if: ProcessInfo.processInfo.environment["MEERKAT_RTSP_TEST_URLS"] != nil
        || FileManager.default.fileExists(atPath: "/tmp/meerkat-rtsp-test-urls"),
    "Requires running mocks configured through MEERKAT_RTSP_TEST_URLS or /tmp/meerkat-rtsp-test-urls"
))
struct RTSPMockIntegrationTests {
    @Test func playsConfiguredMockServers() async throws {
        let configuredURLs = ProcessInfo.processInfo.environment["MEERKAT_RTSP_TEST_URLS"]
            ?? (try? String(contentsOfFile: "/tmp/meerkat-rtsp-test-urls", encoding: .utf8))
        guard let value = configuredURLs?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return }
        let urls = try value.split(separator: ",").map {
            try #require(URL(string: String($0)))
        }
        for url in urls {
            let ingest = RTSPIngest(url: url)
            ingest.stallTimeout = 3
            var states = [PlaybackState]()
            let layer = AVSampleBufferDisplayLayer()
            try ingest.attachDisplay(layer) { states.append($0) }
            ingest.start()
            defer { ingest.stop() }

            await waitUntilRTSP {
                states.contains(.playing) && ingest.enqueuedSampleCount > 0
            }
            #expect(states.contains(.playing))
            #expect(ingest.enqueuedSampleCount > 0)
            ingest.stop()

            try await CameraEndpointCheck(url: url).check()

            var invalidCredentials = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            invalidCredentials.password = "incorrect-fixture-password"
            let rejected = RTSPIngest(url: try #require(invalidCredentials.url))
            var rejectedStates = [PlaybackState]()
            let rejectedLayer = AVSampleBufferDisplayLayer()
            try rejected.attachDisplay(rejectedLayer) { rejectedStates.append($0) }
            rejected.start()
            defer { rejected.stop() }
            await waitUntilRTSP { rejectedStates.contains(.unauthorized) }
            #expect(rejectedStates.contains(.unauthorized))
            rejected.stop()
        }
    }

    @Test func discoversConfiguredMockServersFromBareHost() async throws {
        let configuredURLs = ProcessInfo.processInfo.environment["MEERKAT_RTSP_TEST_URLS"]
            ?? (try? String(contentsOfFile: "/tmp/meerkat-rtsp-test-urls", encoding: .utf8))
        guard let value = configuredURLs?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return }
        let urls = try value.split(separator: ",").map {
            try #require(URL(string: String($0)))
        }
        let credentials = try #require(URLComponents(url: urls[0], resolvingAgainstBaseURL: false))
        let host = try #require(credentials.host)
        let expectedEndpoints = Set(urls.map { "\($0.port ?? 554)|\($0.path)" })
        let container = Persistence.preview(cameras: [])
        var cameras = [Camera]()

        for _ in urls {
            let camera = Camera(name: "Mock", streamURLString: "https://old.test/live")
            camera.authenticationRequired = false
            container.mainContext.insert(camera)
            try container.mainContext.save()
            let editor = CameraConfigurationEditor(camera: camera, debounceDuration: .zero)
            var input = CameraInput(host)
            input.username = credentials.user ?? ""
            input.password = credentials.password ?? ""
            input.requiresAuthentication = credentials.user != nil || credentials.password != nil

            editor.input = input
            await waitUntilRTSP(timeout: .seconds(10)) {
                guard let discovered = camera.playableStreamURL else { return false }
                let endpoint = "\(discovered.port ?? 554)|\(discovered.path)"
                return discovered.scheme == "rtsp" && expectedEndpoints.contains(endpoint)
            }
            cameras.append(camera)
        }

        let discoveredEndpoints = Set(cameras.compactMap { camera -> String? in
            guard let url = camera.playableStreamURL else { return nil }
            return "\(url.port ?? 554)|\(url.path)"
        })
        #expect(discoveredEndpoints == expectedEndpoints)
    }
}

@MainActor
private func waitUntilRTSP(
    timeout: Duration = .seconds(4),
    _ condition: @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition(), "RTSP condition not met before \(timeout)")
}
