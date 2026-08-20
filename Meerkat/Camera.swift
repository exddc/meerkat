import Foundation

struct Camera: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let streamURL: URL

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
}

enum CameraCatalog {
    static let bundled: [Camera] = {
        do {
            let cameras = try load()
#if DEBUG
            print("[Meerkat][Config] loaded \(cameras.count) cameras")
            for camera in cameras {
                print("[Meerkat][Config][\(camera.id)] endpoint=\(camera.logEndpoint)")
            }
#endif
            return cameras
        } catch {
#if DEBUG
            print("[Meerkat][Config] failed to load Cameras.json: \(error)")
#endif
            return []
        }
    }()

    static func load(bundle: Bundle = .main) throws -> [Camera] {
        guard let url = bundle.url(forResource: "Cameras", withExtension: "json") else {
            throw CameraCatalogError.missingConfiguration
        }

        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> [Camera] {
        try JSONDecoder().decode([Camera].self, from: data)
    }
}

private enum CameraCatalogError: Error {
    case missingConfiguration
}
