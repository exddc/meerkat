import Foundation
import SwiftData

@Model
final class Camera {
    var cameraID: UUID
    var name: String
    var streamURLString: String
    var authenticationRequired: Bool? = nil
    var sortIndex: Int
    var isVisible: Bool = true

    init(
        name: String,
        streamURLString: String,
        sortIndex: Int = 0,
        isVisible: Bool = true,
        cameraID: UUID = UUID()
    ) {
        self.cameraID = cameraID
        self.name = name
        self.streamURLString = streamURLString
        self.sortIndex = sortIndex
        self.isVisible = isVisible
    }

    var streamURL: URL {
        URL(string: streamURLString) ?? URL(string: "https://invalid.invalid")!
    }

    var playableStreamURL: URL? {
        guard let parsed = URL(string: streamURLString),
              ["https", "rtsp"].contains(parsed.scheme?.lowercased()),
              let host = parsed.host, !host.isEmpty else {
            return nil
        }
        return streamURL
    }

    func duplicate(among cameras: [Camera]) -> Camera {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName: String
        var number = 2
        if let separator = trimmedName.lastIndex(of: " "),
           let existingNumber = Int(trimmedName[trimmedName.index(after: separator)...]),
           existingNumber < Int.max {
            baseName = String(trimmedName[..<separator])
            number = max(2, existingNumber + 1)
        } else {
            baseName = trimmedName.isEmpty ? "Camera" : trimmedName
        }

        let existingNames = Set(cameras.map { $0.name.lowercased() })
        while existingNames.contains("\(baseName) \(number)".lowercased()) {
            number += 1
        }

        let copy = Camera(
            name: "\(baseName) \(number)",
            streamURLString: streamURLString,
            sortIndex: (cameras.map(\.sortIndex).max() ?? -1) + 1,
            isVisible: isVisible
        )
        copy.authenticationRequired = authenticationRequired
        return copy
    }
}
