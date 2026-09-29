import Foundation
import SwiftData
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
    func acceptsHTTPSAndRTSPPlayback() {
        for url in ["https://192.168.1.2/flv", "rtsp://192.168.1.2/live"] {
            #expect(Camera(name: "", streamURLString: url).playableStreamURL != nil)
        }
        for url in ["http://192.168.1.2/flv", "file:///tmp/stream.flv"] {
            #expect(Camera(name: "", streamURLString: url).playableStreamURL == nil)
        }
    }

    @Test
    func camerasAreVisibleByDefault() {
        let camera = Camera(name: "Front Door", streamURLString: "https://camera.test/live")

        #expect(camera.isVisible)
    }

    @Test
    func duplicateCopiesConnectionSettingsWithUniqueIdentityAndName() {
        let source = Camera(
            name: "Front Door",
            streamURLString: "rtsp://viewer:secret@192.168.1.20/live",
            sortIndex: 0,
            isVisible: false
        )
        source.authenticationRequired = true
        let other = Camera(name: "Front Door 2", streamURLString: "", sortIndex: 4)

        let copy = source.duplicate(among: [source, other])

        #expect(copy.name == "Front Door 3")
        #expect(copy.streamURLString == source.streamURLString)
        #expect(copy.authenticationRequired == source.authenticationRequired)
        #expect(copy.isVisible == source.isVisible)
        #expect(copy.cameraID != source.cameraID)
        #expect(copy.sortIndex == 5)
    }

    @Test
    func duplicateContinuesNumberingFromNumberedCamera() {
        let source = Camera(name: "Camera 3", streamURLString: "https://camera.test/live")
        let existing = Camera(name: "Camera 4", streamURLString: "")

        #expect(source.duplicate(among: [source, existing]).name == "Camera 5")
    }

    @Test
    func duplicateGivesUnnamedCameraAName() {
        let source = Camera(name: "", streamURLString: "https://camera.test/live")

        #expect(source.duplicate(among: [source]).name == "Camera 2")
    }

}

@MainActor
struct CameraPersistenceTests {
    @Test func savesCameraSettingsAcrossContainerRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = ModelConfiguration(
            schema: Persistence.schema,
            url: directory.appending(path: "Meerkat.store")
        )
        let cameraID = UUID()

        do {
            let container = try ModelContainer(
                for: Persistence.schema,
                configurations: [configuration]
            )
            container.mainContext.insert(
                Camera(
                    name: "Front Door",
                    streamURLString: "https://camera.test/live",
                    cameraID: cameraID
                )
            )
            try container.mainContext.save()
        }

        do {
            let container = try ModelContainer(
                for: Persistence.schema,
                configurations: [configuration]
            )
            let cameras = try container.mainContext.fetch(FetchDescriptor<Camera>())
            let camera = try #require(cameras.first { $0.cameraID == cameraID })
            camera.name = "Back Garden"
            camera.streamURLString = "https://camera.test/updated"
            camera.isVisible = false
            try Persistence.save(container.mainContext)
        }

        let reopenedContainer = try ModelContainer(
            for: Persistence.schema,
            configurations: [configuration]
        )
        let cameras = try reopenedContainer.mainContext.fetch(FetchDescriptor<Camera>())

        let camera = try #require(cameras.first { $0.cameraID == cameraID })
        #expect(camera.name == "Back Garden")
        #expect(camera.streamURLString == "https://camera.test/updated")
        #expect(!camera.isVisible)
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

    @Test func importsRTSPCredentialsAndRestoresThemAsUserInfo() throws {
        let input = CameraInput("rtsp://viewer:p%40ss@192.168.1.25:8554/stream1")

        #expect(input.address == "rtsp://192.168.1.25:8554/stream1")
        #expect(input.username == "viewer")
        #expect(input.password == "p@ss")
        let url = try #require(input.streamURL)
        #expect(url.scheme == "rtsp")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.user == "viewer")
        #expect(components.password == "p@ss")
        #expect(url.path == "/stream1")
    }

    @Test func createsVendorCandidatesForBareAddress() throws {
        var input = CameraInput("127.0.0.1:8554")
        input.username = "admin"
        input.password = "meerkat"

        let urls = input.completeStreamURLs

        #expect(urls.count == 5)
        #expect(urls[0].scheme == "https")
        #expect(urls[0].path == "/flv")
        #expect(urls.dropFirst().map(\.scheme) == ["rtsp", "rtsp", "rtsp", "rtsp"])
        #expect(urls.dropFirst().map(\.path) == ["/stream1", "/stream2", "/live0", "/live1"])
        #expect(urls.allSatisfy { $0.port == 8554 })
        #expect(input.completeStreamURLGroups.map { $0.map(\.path) } == [
            ["/flv", "/stream1"],
            ["/live0"],
            ["/stream2"],
            ["/live1"],
        ])
        for url in urls.dropFirst() {
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            #expect(components.user == "admin")
            #expect(components.password == "meerkat")
        }

        input.address = "127.0.0.1"
        let automaticPortURLs = input.completeStreamURLs.filter { $0.scheme == "rtsp" }
        #expect(automaticPortURLs.count == 12)
        #expect(Set(automaticPortURLs.map { $0.port ?? 554 }) == [554, 8554, 8555])
    }

    @Test func rejectsInvalidAddresses() {
        for input in ["", "https://", "http://192.168.1.2", "file:///tmp/live", "not an address", "192.168.1.2:99999"] {
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

    @Test func endpointProbeRejectsRedirects() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureStreamProtocol.self]
        do {
            try await CameraEndpointCheck(url: URL(string: "https://fixture.test/probe-redirect")!).check(configuration: configuration)
            Issue.record("Camera checks must not follow redirects")
        } catch let error as CameraEndpointCheck.Failure {
            #expect(error == .unavailable)
        }
        #expect(FixtureStreamProtocol.counts.withLock { $0["/probe-redirect-target"]?.starts ?? 0 } == 0)
    }

    @Test func endpointProbeValidatesStreamBytesAndStatus() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CameraCheckProtocol.self]
        try await CameraEndpointCheck(url: URL(string: "https://fixture.test/flv")!).check(configuration: configuration)
        for path in ["html", "missing", "unauthorized", "empty", "signature-only", "corrupt", "hevc"] {
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
        input.address = "https://new.test"
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

    @Test func discoversAndPersistsRTSPEndpointForBareAddress() async throws {
        let camera = Camera(name: "Front Door", streamURLString: "https://old.test/live")
        camera.authenticationRequired = false
        let probes = EndpointProbeRecorder()
        let editor = CameraConfigurationEditor(
            camera: camera,
            debounceDuration: .zero,
            endpointCheck: { try await probes.check($0) }
        )

        var input = editor.input
        input.address = "127.0.0.1:8554"
        editor.input = input
        let candidates = input.completeStreamURLs
        let primaryCandidates = try #require(input.completeStreamURLGroups.first)
        let tapoURL = try #require(candidates.first { $0.path == "/stream1" })
        try await waitUntil { await probes.hasStarted(primaryCandidates) }

        #expect(camera.streamURLString == "https://old.test/live")

        await probes.succeed(tapoURL)
        for candidate in primaryCandidates where candidate != tapoURL {
            await probes.fail(candidate)
        }
        try await waitUntil { camera.streamURLString == tapoURL.absoluteString }

        #expect(editor.endpointError == nil)
        #expect(await probes.startedURLs.count == primaryCandidates.count)
        editor.flush()
        #expect(camera.streamURLString == tapoURL.absoluteString)
    }

    @Test func failedDiscoveryDoesNotSaveGuessedEndpoint() async throws {
        let camera = Camera(name: "Camera", streamURLString: "https://old.test/live")
        camera.authenticationRequired = false
        let editor = CameraConfigurationEditor(camera: camera, debounceDuration: .zero, endpointCheck: { _ in
            throw CameraEndpointCheck.Failure.unavailable
        })
        var input = editor.input
        input.address = "127.0.0.1"
        editor.input = input
        try await waitUntil { editor.endpointError != nil }
        editor.flush()
        #expect(camera.streamURLString == "https://old.test/live")
    }

    @Test func discoveryKeepsCredentialFailureAfterOtherCandidatesFail() async throws {
        let camera = Camera(name: "Camera", streamURLString: "https://old.test/live")
        let editor = CameraConfigurationEditor(camera: camera, debounceDuration: .zero, endpointCheck: { url in
            throw url.path == "/live0"
                ? CameraEndpointCheck.Failure.credentials : CameraEndpointCheck.Failure.unavailable
        })
        var input = CameraInput("127.0.0.1")
        input.username = "viewer"
        input.password = "wrong"
        editor.input = input
        try await waitUntil { editor.endpointError != nil }
        #expect(editor.endpointError == "Check the camera username and password.")
        #expect(camera.streamURLString == "https://old.test/live")
    }

    @Test func closingDuringDiscoveryPreservesPreviousAddress() async throws {
        let camera = Camera(name: "Front Door", streamURLString: "https://old.test/live")
        camera.authenticationRequired = false
        let probes = EndpointProbeRecorder()
        let editor = CameraConfigurationEditor(
            camera: camera, debounceDuration: .zero,
            endpointCheck: { try await probes.check($0) }
        )
        var input = editor.input
        input.address = "127.0.0.1:8554"
        editor.input = input
        let candidates = try #require(input.completeStreamURLGroups.first)
        try await waitUntil { await probes.hasStarted(candidates) }
        editor.flush()
        for candidate in candidates { await probes.succeed(candidate) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(camera.streamURLString == "https://old.test/live")
        #expect(await probes.startedURLs.count == candidates.count)
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

    @Test func excludesEndpointAssignedToAnotherCamera() async throws {
        let container = Persistence.preview(cameras: [])
        let tapo = Camera(
            name: "Tapo",
            streamURLString: "rtsp://admin:meerkat@127.0.0.1:8554/stream1"
        )
        let eufy = Camera(name: "Eufy", streamURLString: "https://old.test/live")
        container.mainContext.insert(tapo)
        container.mainContext.insert(eufy)
        try container.mainContext.save()
        let probes = EndpointProbeRecorder()
        let editor = CameraConfigurationEditor(
            camera: eufy,
            debounceDuration: .zero,
            endpointCheck: { try await probes.check($0) }
        )

        var input = CameraInput("127.0.0.1")
        input.username = "admin"
        input.password = "meerkat"
        editor.input = input
        let tapoURL = try #require(input.completeStreamURLs.first {
            $0.port == 8554 && $0.path == "/stream1"
        })
        let firstGroup = try #require(input.completeStreamURLGroups.first)
            .filter { $0 != tapoURL }
        try await waitUntil { await probes.hasStarted(firstGroup) }

        for candidate in firstGroup {
            await probes.fail(candidate)
        }
        let eufyURL = try #require(input.completeStreamURLs.first {
            $0.port == 8555 && $0.path == "/live0"
        })
        let live0Group = try #require(input.completeStreamURLGroups.dropFirst().first)
        try await waitUntil { await probes.hasStarted(live0Group) }
        await probes.succeed(eufyURL)
        for candidate in live0Group where candidate != eufyURL {
            await probes.fail(candidate)
        }
        try await waitUntil { eufy.streamURLString == eufyURL.absoluteString }

        let startedURLs = await probes.startedURLs
        #expect(!startedURLs.contains(tapoURL))
    }

    @Test func duplicateEndpointShowsDuplicateError() async throws {
        let container = Persistence.preview(cameras: [])
        let existing = Camera(name: "Existing", streamURLString: "rtsp://127.0.0.1:8554/stream1")
        let camera = Camera(name: "New", streamURLString: "https://old.test/live")
        camera.authenticationRequired = false
        container.mainContext.insert(existing)
        container.mainContext.insert(camera)
        try container.mainContext.save()
        let editor = CameraConfigurationEditor(camera: camera, debounceDuration: .zero, endpointCheck: { _ in
            Issue.record("Duplicate endpoints must not be probed")
        })
        var input = editor.input
        input.address = existing.streamURLString
        editor.input = input
        try await waitUntil { editor.endpointError != nil }
        #expect(editor.endpointError == "This camera is already added.")
        #expect(camera.streamURLString == "https://old.test/live")
    }

    @Test func doesNotFlushConfigurationIntoDeletedCamera() throws {
        let container = Persistence.preview(cameras: [])
        let camera = Camera(name: "Front Door", streamURLString: "https://old.test/live")
        camera.authenticationRequired = false
        container.mainContext.insert(camera)
        try container.mainContext.save()
        let editor = CameraConfigurationEditor(
            camera: camera,
            debounceDuration: .seconds(30),
            endpointCheck: { _ in }
        )

        var input = editor.input
        input.address = "https://current.test/live"
        editor.input = input
        container.mainContext.delete(camera)
        try container.mainContext.save()
        #expect(camera.modelContext == nil)

        editor.flush()

        #expect(camera.streamURLString == "https://old.test/live")
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

    func hasStarted(_ urls: [URL]) -> Bool {
        urls.allSatisfy { continuations[$0] != nil }
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
            let data: Data
            switch url.path {
            case "/flv": data = FixtureStreamProtocol.fixture
            case "/signature-only": data = Data("FLV".utf8)
            case "/corrupt": data = FixtureStreamProtocol.corruptFixture
            case "/hevc": data = FixtureStreamProtocol.hevcFixture
            default: data = Data("<html>".utf8)
            }
            let bytes = [UInt8](data)
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
