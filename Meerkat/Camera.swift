import Foundation
import SwiftData

@Model
final class Camera {
    var cameraID: UUID
    var name: String
    var streamURLString: String
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
              let host = parsed.host, !host.isEmpty else {
            return nil
        }
        return streamURL
    }

    var logEndpoint: String {
        guard var components = URLComponents(
            url: streamURL,
            resolvingAgainstBaseURL: false
        ) else {
            return "<invalid URL>"
        }

        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "<invalid URL>"
    }

    var logRedactions: [(value: String, replacement: String)] {
        var values = [(streamURL.absoluteString, logEndpoint)]
        let components = URLComponents(
            url: streamURL,
            resolvingAgainstBaseURL: false
        )

        for item in components?.queryItems ?? [] {
            if ["user", "password"].contains(item.name),
               let value = item.value,
               !value.isEmpty {
                values.append((value, "<redacted>"))
            }
        }

        for item in components?.percentEncodedQueryItems ?? [] {
            if ["user", "password"].contains(item.name),
               let value = item.value,
               !value.isEmpty {
                values.append((value, "<redacted>"))
            }
        }

        return values
    }
}
