import Foundation
import SwiftData

@Model
final class Camera {
    var cameraID: UUID
    var name: String
    var streamURLString: String
    var authenticationRequired: Bool? = nil
    var sortIndex: Int

    init(
        name: String,
        streamURLString: String,
        sortIndex: Int = 0,
        cameraID: UUID = UUID()
    ) {
        self.cameraID = cameraID
        self.name = name
        self.streamURLString = streamURLString
        self.sortIndex = sortIndex
    }

    var streamURL: URL {
        URL(string: streamURLString) ?? URL(string: "https://invalid.invalid")!
    }

    var playableStreamURL: URL? {
        guard let parsed = URL(string: streamURLString),
              parsed.scheme == "https",
              let host = parsed.host, !host.isEmpty else {
            return nil
        }
        return streamURL
    }
}
