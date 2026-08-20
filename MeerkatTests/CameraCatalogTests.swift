import Foundation
import Testing
@testable import Meerkat

struct CameraCatalogTests {
    @Test
    func decodesCameraConfiguration() throws {
        let data = Data(
            #"[{"id":"door","name":"Front Door","streamURL":"https://camera.test/live"}]"#.utf8
        )

        let cameras = try CameraCatalog.decode(data)

        #expect(cameras == [
            Camera(
                id: "door",
                name: "Front Door",
                streamURL: URL(string: "https://camera.test/live")!
            ),
        ])
    }

    @Test
    func loadsFourBundledCameras() {
        #expect(CameraCatalog.bundled.map(\.id) == [
            "camera-1",
            "camera-2",
            "camera-3",
            "camera-4",
        ])
    }

    @Test
    func redactsCredentialsFromLogEndpoint() {
        let camera = Camera(
            id: "door",
            name: "Front Door",
            streamURL: URL(
                string: "https://user:secret@camera.test/flv?user=user&password=secret"
            )!
        )

        #expect(camera.logEndpoint == "https://camera.test/flv")
    }

    @Test
    func preservesLiteralBangInStreamPassword() throws {
        let data = Data(
            #"[{"id":"door","name":"Front Door","streamURL":"https://camera.test/flv?user=viewer&password=secret!"}]"#.utf8
        )

        let camera = try #require(CameraCatalog.decode(data).first)

        #expect(camera.streamURL.absoluteString.contains("password=secret!"))
        #expect(!camera.streamURL.absoluteString.contains("%21"))
    }
}
