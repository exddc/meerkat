import AVFoundation
import Synchronization
import CoreMedia
import Foundation
import Testing
@testable import Meerkat

struct FLVPlaybackTests {
    private let header = Data([0x46, 0x4c, 0x56, 1, 1, 0, 0, 0, 9, 0, 0, 0, 0])
    private let sps: [UInt8] = [0x67, 0x42, 0xc0, 0x16, 0xd9, 0x0, 0xa0, 0x2f, 0xf9, 0x70, 0x11, 0x0, 0x0, 0x3, 0x0, 0x1, 0x0, 0x0, 0x3, 0x0, 0x14, 0xf, 0x16, 0x2e, 0x48]
    private let pps: [UInt8] = [0x68, 0xcb, 0x83, 0xcb, 0x20]

    private func tag(_ payload: Data, type: UInt8 = 9, timestamp: UInt32 = 0) -> Data {
        let size = payload.count
        return Data([type, UInt8(size >> 16), UInt8((size >> 8) & 255), UInt8(size & 255),
                     UInt8((timestamp >> 16) & 255), UInt8((timestamp >> 8) & 255), UInt8(timestamp & 255),
                     UInt8(timestamp >> 24), 0, 0, 0]) + payload
            + Data([0, UInt8((size + 11) >> 16), UInt8(((size + 11) >> 8) & 255), UInt8((size + 11) & 255)])
    }

    private func sequence(length: UInt8 = 3) -> FLVTag {
        FLVTag(type: 9, timestamp: 0, payload: Data([0x17, 0, 0, 0, 0, 1, 0x42, 0xc0, 0x1e,
            0xfc | length, 0xe1, 0, UInt8(sps.count)] + sps + [1, 0, UInt8(pps.count)] + pps))
    }

    @Test func parsesEverySplitAndIgnoresAudio() throws {
        let payload = Data([0x17, 1, 0, 0, 0, 0, 0, 0, 2, 0x65, 0x88])
        let bytes = header + tag(Data([1, 2, 3]), type: 8) + tag(payload, timestamp: 0xab123456)
        for split in 0...bytes.count {
            var parser = FLVParser()
            let tags = try parser.append(Data(bytes.prefix(split))) + parser.append(Data(bytes.dropFirst(split)))
            #expect(tags.count == 1)
            #expect(tags.first?.timestamp == 0xab123456)
            #expect(tags.first?.payload == payload)
        }
        var parser = FLVParser()
        var tags = [FLVTag]()
        for byte in bytes { tags += try parser.append(Data([byte])) }
        #expect(tags.count == 1)
    }

    @Test func rejectsInvalidHeaderAndTagSizes() throws {
        var parser = FLVParser()
        #expect(throws: FLVError.self) { try parser.append(Data(repeating: 0, count: 13)) }
        parser = FLVParser()
        var bytes = header + tag(Data([1]))
        bytes[bytes.count - 1] = 0
        #expect(throws: FLVError.self) { try parser.append(bytes) }
        parser = FLVParser()
        let oversized = header + Data([9, 0x21, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(throws: FLVError.self) { try parser.append(oversized) }
    }

    @Test func packsNALUnitsAndSignedCompositionTime() throws {
        var builder = AVCSampleBuilder()
        #expect(try builder.sample(for: sequence()) == nil)
        #expect(builder.format != nil)
        let nals = Data([0, 0, 0, 2, 0x65, 0x88, 0, 0, 0, 2, 0x65, 0x99])
        let packed = try builder.sample(for: FLVTag(type: 9, timestamp: 100,
            payload: Data([0x17, 1, 0xff, 0xff, 0xfe]) + nals))
        let sample = try #require(packed)
        #expect(CMSampleBufferGetPresentationTimeStamp(sample) == CMTime(value: 98, timescale: 1000))
        #expect(CMSampleBufferGetDecodeTimeStamp(sample) == CMTime(value: 100, timescale: 1000))
        let block = try #require(CMSampleBufferGetDataBuffer(sample))
        var copied = Data(count: nals.count)
        let status = copied.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: nals.count, destination: $0.baseAddress!)
        }
        #expect(status == noErr)
        #expect(copied == nals)
        let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]])
        #expect(attachments[0][kCMSampleAttachmentKey_DisplayImmediately as String] == nil)
        #expect(attachments[0][kCMSampleAttachmentKey_NotSync as String] as? Bool == false)
    }

    @Test func waitsForIDRAndRejectsTruncatedNAL() throws {
        var builder = AVCSampleBuilder()
        let delta = FLVTag(type: 9, timestamp: 0, payload: Data([0x27, 1, 0, 0, 0, 0, 0, 0, 1, 0x41]))
        #expect(try builder.sample(for: delta) == nil)
        _ = try builder.sample(for: sequence())
        #expect(try builder.sample(for: delta) == nil)
        #expect(throws: FLVError.self) {
            try builder.sample(for: FLVTag(type: 9, timestamp: 0, payload: Data([0x17, 1, 0, 0, 0, 0, 0, 0, 9, 0x65])))
        }
        #expect(throws: FLVError.self) { try builder.sample(for: sequence(length: 2)) }
    }

    @Test func handlesShortNALLengthsAndTimestampWrap() throws {
        for length: UInt8 in [0, 1, 3] {
            var builder = AVCSampleBuilder()
            _ = try builder.sample(for: sequence(length: length))
            let nals = Data(repeating: 0, count: Int(length)) + Data([1, 0x65])
            let first = try builder.sample(for: FLVTag(type: 9, timestamp: UInt32.max - 1,
                payload: Data([0x17, 1, 0, 0, 2]) + nals))
            #expect(first != nil)
            let second = try builder.sample(for: FLVTag(type: 9, timestamp: 3,
                payload: Data([0x17, 1, 0, 0, 0]) + nals))
            let sample = try #require(second)
            #expect(CMSampleBufferGetDecodeTimeStamp(sample) == CMTime(value: (1 << 32) + 3, timescale: 1000))
        }
    }

    @Test func acceptsOnlyConfiguredPrivateCameraCertificate() {
        for host in ["10.0.0.2", "172.16.0.2", "192.168.1.2", "169.254.1.2", "[fd00::1]"] {
            let url = URL(string: "https://\(host)/flv")!
            #expect(CameraCertificateTrust.allows(url: url, host: url.host!))
        }
        for host in ["8.8.8.8", "172.32.0.1", "127.0.0.1", "camera.example", "[::1]"] {
            let url = URL(string: "https://\(host)/flv")!
            #expect(!CameraCertificateTrust.allows(url: url, host: url.host!))
        }
        #expect(!CameraCertificateTrust.allows(url: URL(string: "https://192.168.1.2/flv")!, host: "192.168.1.3"))
        #expect(!CameraCertificateTrust.allows(url: URL(string: "http://192.168.1.2/flv")!, host: "192.168.1.2"))
    }
}

private final class FixtureStreamProtocol: URLProtocol, @unchecked Sendable {
    static let counts = Mutex<[String: (starts: Int, stops: Int)]>([:])
    static let fixture = Data(base64Encoded: "RkxWAQEAAAAJAAAAABIAALcAAAAAAAAAAgAKb25NZXRhRGF0YQgAAAAIAAhkdXJhdGlvbgA/8AAAAAAAAAAFd2lkdGgAQIQAAAAAAAAABmhlaWdodABAdoAAAAAAAAANdmlkZW9kYXRhcmF0ZQAAAAAAAAAAAAAJZnJhbWVyYXRlAEAkAAAAAAAAAAx2aWRlb2NvZGVjaWQAQBwAAAAAAAAAB2VuY29kZXICAAxMYXZmNjMuMS4xMDEACGZpbGVzaXplAECeWAAAAAAAAAAJAAAAwgkAAC4AAAAAAAAAFwAAAAABQsAW/+EAGWdCwBbZAKAv+XARAAADAAEAAAMAFA8WLkgBAAVoy4PLIAAAADkJAAVLAAAAAAAAABcBAAAAAAACcAYF//9s3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTMgZGVibG9jaz0xOjA6MCBhbmFseXNlPTB4MToweDExMSBtZT1oZXggc3VibWU9NyBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0xIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MSA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0tMiB0aHJlYWRzPTExIGxvb2thaGVhZF90aHJlYWRzPTEgc2xpY2VkX3RocmVhZHM9MCBucj0wIGRlY2ltYXRlPTEgaW50ZXJsYWNlZD0wIGJsdXJheV9jb21wYXQ9MCBjb25zdHJhaW5lZF9pbnRyYT0wIGJmcmFtZXM9MCB3ZWlnaHRwPTAga2V5aW50PTEwIGtleWludF9taW49MSBzY2VuZWN1dD00MCBpbnRyYV9yZWZyZXNoPTAgcmNfbG9va2FoZWFkPTEwIHJjPWNyZiBtYnRyZWU9MSBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBfcmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAs5liIQP8RigAC0jHAAFXKOAAIYMnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJycnJyddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddeAAAFVgkAABAAAGQAAAAAJwEAAAAAAAAHQZo4H+AOZgAAABsJAAARAADIAAAAACcBAAAAAAAACEGaVAf4A5mAAAAAHAkAABAAASwAAAAAJwEAAAAAAAAHQZpgP8AczAAAABsJAAAQAAGQAAAAACcBAAAAAAAAB0GagD/AHMwAAAAbCQAAEAAB9AAAAAAnAQAAAAAAAAdBmqA/wBzMAAAAGwkAABAAAlgAAAAAJwEAAAAAAAAHQZrAP8AczAAAABsJAAAQAAK8AAAAACcBAAAAAAAAB0Ga4D/AHMwAAAAbCQAAEAADIAAAAAAnAQAAAAAAAAdBmwA7wBzMAAAAGwkAABAAA4QAAAAAJwEAAAAAAAAHQZsgN8AczAAAABsJAAAFAAOEAAAAABcCAAAAAAAAEA==")!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.counts.withLock { $0[url.path, default: (0, 0)].starts += 1 }
        if url.path == "/failure" {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        } else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "video/x-flv"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.fixture)
        }
    }

    override func stopLoading() {
        let path = request.url!.path
        Self.counts.withLock { $0[path, default: (0, 0)].stops += 1 }
    }
}

@MainActor
struct HTTPFLVPlayerTests {
    @Test func decodesFixtureAndReleasesSessionOnStop() async throws {
        let view = SampleBufferVideoView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        let displayLayer = view.prepareLayer()
        let renderer = displayLayer.sampleBufferRenderer
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureStreamProtocol.self]
        var player: HTTPFLVPlayer? = try HTTPFLVPlayer(url: URL(string: "https://fixture.test/stream")!,
            displayLayer: displayLayer, configuration: configuration, onStateChange: { _ in })
        weak var releasedPlayer = player
        player?.start()
        defer { player?.stop(); view.removeDisplayLayer() }
        try await Task.sleep(for: .seconds(1))
        #expect(renderer.status == .rendering)
        let timebase = try #require(displayLayer.controlTimebase)
        #expect(CMTimebaseGetRate(timebase) == 1)
        player?.stop()
        view.removeDisplayLayer()
        player = nil
        try await Task.sleep(for: .milliseconds(200))
        #expect(view.displayLayer == nil)
        #expect(releasedPlayer == nil)
        #expect(FixtureStreamProtocol.counts.withLock { $0["/stream"]?.stops } == 1)
    }

    @Test func retriesBeforeFirstFrameAndCancelsPendingRetry() async throws {
        let displayLayer = AVSampleBufferDisplayLayer()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureStreamProtocol.self]
        var states = [PlaybackState]()
        let player = try HTTPFLVPlayer(url: URL(string: "https://fixture.test/failure")!,
            displayLayer: displayLayer, configuration: configuration, onStateChange: { states.append($0) })
        player.start()
        defer { player.stop() }
        try await Task.sleep(for: .milliseconds(2400))
        #expect(states.contains(.reconnecting))
        #expect(FixtureStreamProtocol.counts.withLock { $0["/failure"]?.starts } == 2)
        player.stop()
        try await Task.sleep(for: .milliseconds(2400))
        #expect(FixtureStreamProtocol.counts.withLock { $0["/failure"]?.starts } == 2)
    }
}
