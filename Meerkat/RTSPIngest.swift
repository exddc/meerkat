import AVFoundation
import CryptoKit
import Foundation
import Network

@MainActor
final class RTSPIngest: CameraIngest {
    static let retryDelay = Duration.seconds(2)
    static let failureRetryDelay = Duration.seconds(30)
    static let stallTimeout: TimeInterval = 10

    var retryDelay = RTSPIngest.retryDelay
    var failureRetryDelay = RTSPIngest.failureRetryDelay
    var stallTimeout = RTSPIngest.stallTimeout
    var enqueuedSampleCount: Int { output.enqueuedSampleCount }
    var bufferedSampleCount: Int { output.bufferedSampleCount }

    private enum Phase {
        case disconnected
        case describing
        case settingUp(URL)
        case playing
        case streaming
    }

    private let url: URL
    private lazy var output = SampleBufferDisplaySink { [weak self] failure in
        self?.fail(failure)
    }
    private var connection: NWConnection?
    private var parser = RTSPMessageParser()
    private var depacketizer = RTPH264Depacketizer()
    private var sampleBuilder = RTPH264SampleBuilder()
    private var phase = Phase.disconnected
    private var sequence = 0
    private var authentication: RTSPAuthentication?
    private var pendingRequest: (method: String, uri: URL, headers: [String: String], retried: Bool)?
    private var sessionID: String?
    private var rtpChannel: UInt8 = 0
    private var retry: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?
    private var lastFrame = Date()
    private var active = false
    private var state = PlaybackState.connecting

    init(url: URL) {
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
        disconnect(clearBuffer: true)
        output.detach()
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
        guard active, let host = url.host,
              let portNumber = UInt16(exactly: url.port ?? 554),
              let port = NWEndpoint.Port(rawValue: portNumber) else {
            fail(.unsupported)
            return
        }
        parser = RTSPMessageParser()
        depacketizer = RTPH264Depacketizer()
        sampleBuilder = RTPH264SampleBuilder()
        phase = .disconnected
        sequence = 0
        authentication = nil
        pendingRequest = nil
        sessionID = nil
        rtpChannel = 0
        lastFrame = Date()

        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] newState in
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                switch newState {
                case .ready:
                    self.phase = .describing
                    self.send("DESCRIBE", uri: self.requestURL, headers: ["Accept": "application/sdp"])
                case .failed:
                    self.fail(.reconnecting)
                default:
                    break
                }
            }
        }
        receive(from: connection)
        connection.start(queue: .main)
        startWatchdog()
    }

    private func receive(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self, weak connection] data, _, complete, error in
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                if let data, !data.isEmpty {
                    do {
                        try self.process(data)
                    } catch let error as RTSPError {
                        self.fail(error.playbackState)
                        return
                    } catch {
                        self.fail(.reconnecting)
                        return
                    }
                }
                if complete || error != nil {
                    self.fail(.reconnecting)
                } else {
                    self.receive(from: connection)
                }
            }
        }
    }

    private func process(_ data: Data) throws {
        for event in try parser.append(data) {
            switch event {
            case .response(let response):
                process(response)
            case .interleaved(let channel, let packet):
                guard case .streaming = phase, channel == rtpChannel,
                      let frame = try depacketizer.append(packet),
                      let sample = try sampleBuilder.sample(for: frame) else { continue }
                try output.accept(sample)
                lastFrame = Date()
                if output.bufferedSampleCount > 0 {
                    report(.playing)
                }
            }
        }
    }

    private func process(_ response: RTSPResponse) {
        guard response.headers["cseq"] == String(sequence), let request = pendingRequest else { return }
        pendingRequest = nil
        if response.statusCode == 401, !request.retried,
           let challenge = response.headers["www-authenticate"],
           let credentials = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let user = credentials.user, let password = credentials.password,
           let authentication = RTSPAuthentication(challenge: challenge, user: user, password: password) {
            self.authentication = authentication
            send(request.method, uri: request.uri, headers: request.headers, retried: true)
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 {
                fail(.unauthorized)
            } else if response.statusCode == 404 || response.statusCode == 405
                        || response.statusCode == 415 || response.statusCode == 461 {
                fail(.unsupported)
            } else {
                fail(.reconnecting)
            }
            return
        }

        switch phase {
        case .describing:
            guard let description = RTSPSessionDescription(response: response, requestURL: requestURL) else {
                fail(.unsupported)
                return
            }
            sampleBuilder.setParameterSets(sps: description.sps, pps: description.pps)
            phase = .settingUp(description.trackURL)
            send(
                "SETUP",
                uri: description.trackURL,
                headers: ["Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"]
            )
        case .settingUp:
            guard let session = response.headers["session"]?.split(separator: ";").first,
                  !session.isEmpty else {
                fail(.unsupported)
                return
            }
            if let header = response.headers["transport"] {
                guard let transport = RTSPInterleavedTransport(header: header) else {
                    fail(.unsupported)
                    return
                }
                rtpChannel = transport.rtpChannel
            }
            sessionID = String(session)
            phase = .playing
            send("PLAY", uri: requestURL)
        case .playing:
            phase = .streaming
            startKeepalive()
        case .streaming, .disconnected:
            break
        }
    }

    private func send(_ method: String, uri: URL, headers: [String: String] = [:], retried: Bool = false) {
        guard let connection else { return }
        guard pendingRequest == nil else { return }
        pendingRequest = (method, uri, headers, retried)
        sequence += 1
        var fields = headers
        fields["CSeq"] = String(sequence)
        fields["User-Agent"] = "Meerkat"
        if let sessionID {
            fields["Session"] = sessionID
        }
        if let authorization = authentication?.authorization(method: method, uri: uri.absoluteString) {
            fields["Authorization"] = authorization
        }
        let headerLines = fields.map { "\($0.key): \($0.value)" }.sorted()
        let request = (["\(method) \(uri.absoluteString) RTSP/1.0"] + headerLines + ["", ""])
            .joined(separator: "\r\n")
        connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self, weak connection] error in
            guard error != nil else { return }
            Task { @MainActor in
                guard let self, let connection, self.connection === connection else { return }
                self.fail(.reconnecting)
            }
        })
    }

    private var requestURL: URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.user = nil
        components.password = nil
        return components.url ?? url
    }

    private func startWatchdog() {
        let tick = min(1, max(stallTimeout / 5, 0.05))
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(tick))
                guard !Task.isCancelled, let self else { return }
                if Date().timeIntervalSince(self.lastFrame) > self.stallTimeout
                    || self.output.rendererFailed {
                    self.fail(.reconnecting)
                    return
                }
            }
        }
    }

    private func startKeepalive() {
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self else { return }
                self.send("OPTIONS", uri: self.requestURL)
            }
        }
    }

    private func disconnect(clearBuffer: Bool) {
        watchdog?.cancel()
        watchdog = nil
        keepalive?.cancel()
        keepalive = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        phase = .disconnected
        if clearBuffer {
            output.reset()
        }
    }

    private func fail(_ failure: PlaybackState) {
        guard active, retry == nil else { return }
        disconnect(clearBuffer: true)
        report(failure)
        let delay = failure == .reconnecting ? retryDelay : failureRetryDelay
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.retry = nil
            self.connect()
        }
    }

    private func report(_ newState: PlaybackState) {
        guard state != newState else { return }
        state = newState
        output.report(newState)
    }
}

struct RTSPResponse: Equatable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

enum RTSPEvent: Equatable {
    case response(RTSPResponse)
    case interleaved(channel: UInt8, packet: Data)
}

struct RTSPAuthentication {
    private let user: String
    private let password: String
    private let fields: [String: String]
    private let basic: Bool
    private let cnonce: String
    private var nonceCount = 0

    init?(challenge: String, user: String, password: String, cnonce: String = UUID().uuidString) {
        guard ![challenge, user, cnonce].contains(where: { $0.contains("\r") || $0.contains("\n") }) else { return nil }
        let parts = challenge.split(separator: " ", maxSplits: 1)
        guard let scheme = parts.first?.lowercased(), ["basic", "digest"].contains(scheme) else { return nil }
        basic = scheme == "basic"
        var fields = [String: String]()
        if !basic {
            guard parts.count == 2,
                  let expression = try? NSRegularExpression(pattern: #"(\w+)\s*=\s*(?:"((?:\\.|[^"\\])*)"|([^,\s]+))"#) else { return nil }
            let parameters = String(parts[1])
            for match in expression.matches(in: parameters, range: NSRange(parameters.startIndex..., in: parameters)) {
                guard let keyRange = Range(match.range(at: 1), in: parameters),
                      let valueRange = Range(match.range(at: match.range(at: 2).location == NSNotFound ? 3 : 2), in: parameters) else { continue }
                fields[String(parameters[keyRange]).lowercased()] = String(parameters[valueRange])
                    .replacingOccurrences(of: #"\""#, with: "\"")
                    .replacingOccurrences(of: #"\\"#, with: #"\"#)
            }
            guard fields["realm"] != nil, let nonce = fields["nonce"], !nonce.isEmpty,
                  ["md5", "md5-sess"].contains(fields["algorithm", default: "MD5"].lowercased()) else { return nil }
            if let qop = fields["qop"] {
                guard qop.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "auth" }) else { return nil }
            }
        }
        self.fields = fields
        self.user = user
        self.password = password
        self.cnonce = cnonce
    }

    mutating func authorization(method: String, uri: String) -> String {
        if basic { return "Basic \(Data("\(user):\(password)".utf8).base64EncodedString())" }
        let realm = fields["realm", default: ""]
        let nonce = fields["nonce", default: ""]
        let algorithm = fields["algorithm", default: "MD5"]
        nonceCount += 1
        let nc = String(format: "%08x", nonceCount)
        var ha1 = Self.md5("\(user):\(realm):\(password)")
        if algorithm.lowercased() == "md5-sess" { ha1 = Self.md5("\(ha1):\(nonce):\(cnonce)") }
        let ha2 = Self.md5("\(method):\(uri)")
        let response = fields["qop"] == nil
            ? Self.md5("\(ha1):\(nonce):\(ha2)")
            : Self.md5("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
        var values = ["username=\(Self.quoted(user))", "realm=\(Self.quoted(realm))",
                      "nonce=\(Self.quoted(nonce))", "uri=\(Self.quoted(uri))",
                      "response=\(Self.quoted(response))", "algorithm=\(algorithm)"]
        if let opaque = fields["opaque"] { values.append("opaque=\(Self.quoted(opaque))") }
        if fields["qop"] != nil { values += ["qop=auth", "nc=\(nc)"] }
        if fields["qop"] != nil || algorithm.lowercased() == "md5-sess" {
            values.append("cnonce=\(Self.quoted(cnonce))")
        }
        return "Digest " + values.joined(separator: ", ")
    }

    private static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

struct RTSPMessageParser {
    private static let maximumBufferedBytes = 1024 * 1024
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [RTSPEvent] {
        buffer.append(data)
        guard buffer.count <= Self.maximumBufferedBytes else { throw RTSPError.invalidMessage }
        var events = [RTSPEvent]()
        var offset = 0
        defer { if offset > 0 { buffer = Data(buffer.dropFirst(offset)) } }
        while offset < buffer.count {
            if buffer[offset] == 0x24 {
                guard buffer.count - offset >= 4 else { break }
                let size = Int(buffer.integer(at: offset + 2, count: 2))
                guard buffer.count - offset >= size + 4 else { break }
                events.append(.interleaved(
                    channel: buffer[offset + 1],
                    packet: buffer.subdata(in: (offset + 4)..<(offset + size + 4))
                ))
                offset += size + 4
                continue
            }

            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8), in: offset..<buffer.count) else { break }
            let headerData = buffer[offset..<headerEnd.lowerBound]
            guard let header = String(data: headerData, encoding: .utf8) else {
                throw RTSPError.invalidMessage
            }
            let lines = header.components(separatedBy: "\r\n")
            guard let status = lines.first?.split(separator: " "), status.count >= 2,
                  status[0] == "RTSP/1.0", let statusCode = Int(status[1]) else {
                throw RTSPError.invalidMessage
            }
            let fields: [(String, String)] = lines.dropFirst().compactMap { line in
                guard let separator = line.firstIndex(of: ":") else { return nil }
                let name = line[..<separator].lowercased()
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                return (name, value)
            }
            let headers = fields.reduce(into: [String: String]()) { result, field in
                if field.0 == "www-authenticate", result[field.0]?.lowercased().hasPrefix("digest ") == true { return }
                result[field.0] = field.1
            }
            guard let contentLength = Int(headers["content-length"] ?? "0"),
                  contentLength >= 0, contentLength <= Self.maximumBufferedBytes else {
                throw RTSPError.invalidMessage
            }
            let bodyStart = headerEnd.upperBound
            guard buffer.count >= bodyStart + contentLength else { break }
            let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
            events.append(.response(RTSPResponse(
                statusCode: statusCode,
                headers: headers,
                body: body
            )))
            offset = bodyStart + contentLength
        }
        return events
    }
}

struct RTSPInterleavedTransport: Equatable {
    let rtpChannel: UInt8
    let rtcpChannel: UInt8

    init?(header: String) {
        for specification in header.split(separator: ",") {
            let fields = specification.split(separator: ";").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.first?.uppercased() == "RTP/AVP/TCP" else { continue }
            guard let value = fields.dropFirst().compactMap({ field -> Substring? in
                let parts = field.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, parts[0].lowercased() == "interleaved" else { return nil }
                return parts[1]
            }).first else { continue }
            let channels = value.split(separator: "-", maxSplits: 1)
            guard channels.count == 2,
                  let rtpChannel = UInt8(channels[0]),
                  let rtcpChannel = UInt8(channels[1]) else { return nil }
            self.rtpChannel = rtpChannel
            self.rtcpChannel = rtcpChannel
            return
        }
        return nil
    }
}

private struct RTSPSessionDescription {
    let trackURL: URL
    let sps: Data?
    let pps: Data?

    init?(response: RTSPResponse, requestURL: URL) {
        guard let text = String(data: response.body, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        guard let videoStart = lines.firstIndex(where: { $0.lowercased().hasPrefix("m=video ") }) else {
            return nil
        }
        let videoLines = lines[videoStart...].prefix { line in
            line == lines[videoStart] || !line.lowercased().hasPrefix("m=")
        }
        guard videoLines.contains(where: {
            $0.lowercased().hasPrefix("a=rtpmap:") && $0.lowercased().contains("h264/90000")
        }) else { return nil }
        let control = videoLines.first(where: { $0.lowercased().hasPrefix("a=control:") })?
            .dropFirst("a=control:".count)
        guard let control, !control.isEmpty, control != "*" else { return nil }
        let base = response.headers["content-base"].flatMap(URL.init(string:)) ?? requestURL
        guard let trackURL = URL(string: String(control), relativeTo: base)?.absoluteURL else { return nil }

        let parameterText = videoLines.first(where: { $0.lowercased().contains("sprop-parameter-sets=") })
        let values = parameterText.flatMap { line -> [Substring]? in
            guard let range = line.range(of: "sprop-parameter-sets=", options: .caseInsensitive) else {
                return nil
            }
            return line[range.upperBound...].split(separator: ";", maxSplits: 1)[0].split(separator: ",")
        }
        self.trackURL = trackURL
        sps = values?.first.flatMap { Data(base64Encoded: String($0)) }
        pps = values.flatMap { $0.count > 1 ? Data(base64Encoded: String($0[1])) : nil }
    }
}

struct RTPH264Frame: Equatable {
    let timestamp: UInt32
    let nalUnits: [Data]
}

struct RTPH264Depacketizer {
    private var timestamp: UInt32?
    private var nalUnits = [Data]()
    private var fragment: Data?
    private var lastSequence: UInt16?

    mutating func append(_ packet: Data) throws -> RTPH264Frame? {
        guard packet.count >= 12, packet[0] >> 6 == 2 else { throw RTSPError.invalidRTP }
        let marker = packet[1] & 0x80 != 0
        let sequence = UInt16(packet.integer(at: 2, count: 2))
        let packetTimestamp = UInt32(packet.integer(at: 4, count: 4))
        var offset = 12 + Int(packet[0] & 0x0f) * 4
        guard offset <= packet.count else { throw RTSPError.invalidRTP }
        if packet[0] & 0x10 != 0 {
            guard offset + 4 <= packet.count else { throw RTSPError.invalidRTP }
            let extensionWords = Int(packet.integer(at: offset + 2, count: 2))
            offset += 4 + extensionWords * 4
            guard offset <= packet.count else { throw RTSPError.invalidRTP }
        }
        var payloadEnd = packet.count
        if packet[0] & 0x20 != 0 {
            guard let padding = packet.last, padding > 0, Int(padding) <= payloadEnd - offset else {
                throw RTSPError.invalidRTP
            }
            payloadEnd -= Int(padding)
        }
        guard offset < payloadEnd else { throw RTSPError.invalidRTP }

        if let lastSequence, sequence != lastSequence &+ 1 {
            resetFrame()
        }
        self.lastSequence = sequence
        if let timestamp, timestamp != packetTimestamp {
            resetFrame()
        }
        timestamp = packetTimestamp
        let payload = packet.subdata(in: offset..<payloadEnd)
        try appendPayload(payload)

        guard marker else { return nil }
        guard fragment == nil, !nalUnits.isEmpty else {
            resetFrame()
            return nil
        }
        let frame = RTPH264Frame(timestamp: packetTimestamp, nalUnits: nalUnits)
        resetFrame()
        return frame
    }

    private mutating func appendPayload(_ payload: Data) throws {
        let type = payload[0] & 0x1f
        switch type {
        case 1...23:
            fragment = nil
            nalUnits.append(payload)
        case 24:
            fragment = nil
            var offset = 1
            while offset < payload.count {
                guard offset + 2 <= payload.count else { throw RTSPError.invalidRTP }
                let size = Int(payload.integer(at: offset, count: 2))
                offset += 2
                guard size > 0, offset + size <= payload.count else { throw RTSPError.invalidRTP }
                nalUnits.append(payload.subdata(in: offset..<(offset + size)))
                offset += size
            }
        case 28:
            guard payload.count >= 2 else { throw RTSPError.invalidRTP }
            let start = payload[1] & 0x80 != 0
            let end = payload[1] & 0x40 != 0
            if start {
                let header = (payload[0] & 0xe0) | (payload[1] & 0x1f)
                fragment = Data([header]) + payload.dropFirst(2)
            } else if fragment != nil {
                fragment?.append(payload.dropFirst(2))
            }
            if end, let fragment {
                nalUnits.append(fragment)
                self.fragment = nil
            }
        default:
            throw RTSPError.unsupportedPacketization
        }
    }

    private mutating func resetFrame() {
        timestamp = nil
        nalUnits.removeAll(keepingCapacity: true)
        fragment = nil
    }
}

struct RTPH264SampleBuilder {
    private var builder = AVCSampleBuilder()
    private var sps: Data?
    private var pps: Data?
    private var configuredSPS: Data?
    private var configuredPPS: Data?
    private var timestampEpoch: UInt64 = 0
    private var lastTimestamp: UInt32?

    mutating func setParameterSets(sps: Data?, pps: Data?) {
        if let sps { self.sps = sps }
        if let pps { self.pps = pps }
    }

    mutating func sample(for frame: RTPH264Frame) throws -> CMSampleBuffer? {
        var videoNALs = [Data]()
        for nal in frame.nalUnits where !nal.isEmpty {
            switch nal[0] & 0x1f {
            case 7: sps = nal
            case 8: pps = nal
            case 9: break
            default: videoNALs.append(nal)
            }
        }
        try configureIfNeeded()
        guard !videoNALs.isEmpty else { return nil }
        let keyframe = videoNALs.contains { $0[0] & 0x1f == 5 }
        var payload = Data([keyframe ? 0x17 : 0x27, 1, 0, 0, 0])
        for nal in videoNALs {
            guard nal.count <= Int(UInt32.max) else { throw RTSPError.invalidRTP }
            payload.append(contentsOf: withUnsafeBytes(of: UInt32(nal.count).bigEndian, Array.init))
            payload.append(nal)
        }
        if let lastTimestamp, frame.timestamp < lastTimestamp,
           lastTimestamp - frame.timestamp > UInt32.max / 2 {
            timestampEpoch += 1 << 32
        }
        lastTimestamp = frame.timestamp
        let milliseconds = UInt32(((timestampEpoch + UInt64(frame.timestamp)) / 90) & UInt64(UInt32.max))
        return try builder.sample(for: FLVTag(
            type: FLVTag.video,
            timestamp: milliseconds,
            payload: payload
        ))
    }

    private mutating func configureIfNeeded() throws {
        guard let sps, let pps, !sps.isEmpty, !pps.isEmpty,
              sps != configuredSPS || pps != configuredPPS else { return }
        guard sps.count <= Int(UInt16.max), pps.count <= Int(UInt16.max), sps.count >= 4 else {
            throw RTSPError.invalidSDP
        }
        var configuration = Data([1, sps[1], sps[2], sps[3], 0xff, 0xe1])
        configuration.append(contentsOf: withUnsafeBytes(of: UInt16(sps.count).bigEndian, Array.init))
        configuration.append(sps)
        configuration.append(1)
        configuration.append(contentsOf: withUnsafeBytes(of: UInt16(pps.count).bigEndian, Array.init))
        configuration.append(pps)
        _ = try builder.sample(for: FLVTag(
            type: FLVTag.video,
            timestamp: 0,
            payload: Data([0x17, 0, 0, 0, 0]) + configuration
        ))
        configuredSPS = sps
        configuredPPS = pps
    }
}

enum RTSPError: Error {
    case invalidMessage
    case invalidRTP
    case invalidSDP
    case unsupportedPacketization

    var playbackState: PlaybackState {
        switch self {
        case .invalidMessage, .invalidRTP:
            .reconnecting
        case .invalidSDP, .unsupportedPacketization:
            .unsupported
        }
    }
}
