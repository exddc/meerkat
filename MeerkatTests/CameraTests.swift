import Foundation
import Testing
@testable import Meerkat

struct CameraTests {
    @Test
    func redactsCredentialsFromLogEndpoint() {
        let camera = Camera(
            name: "Front Door",
            streamURLString: "https://user:secret@camera.test/flv?user=user&password=secret"
        )

        #expect(camera.logEndpoint == "https://camera.test/flv")
    }

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
}
