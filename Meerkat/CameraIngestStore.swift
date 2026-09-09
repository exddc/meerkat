import Combine
import Foundation

struct CameraIngestConfiguration: Equatable {
    let cameraID: UUID
    let url: URL?

    init(camera: Camera) {
        cameraID = camera.cameraID
        url = camera.playableStreamURL
    }

    init(cameraID: UUID, url: URL?) {
        self.cameraID = cameraID
        self.url = url
    }
}

@MainActor
final class CameraIngestStore: ObservableObject {
    @Published private(set) var revision = 0

    private struct Entry {
        let url: URL
        let ingest: HTTPFLVIngest
    }

    private let sessionConfiguration: URLSessionConfiguration
    private var entries = [UUID: Entry]()

    init(sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.sessionConfiguration = sessionConfiguration
    }

    func synchronize(_ configurations: [CameraIngestConfiguration]) {
        let desired = Dictionary(
            uniqueKeysWithValues: configurations.compactMap { configuration in
                configuration.url.map { (configuration.cameraID, $0) }
            }
        )
        var changed = false

        for cameraID in Array(entries.keys) where desired[cameraID] == nil {
            entries.removeValue(forKey: cameraID)?.ingest.stop()
            changed = true
        }

        for (cameraID, url) in desired {
            if let entry = entries[cameraID], entry.url == url {
                continue
            }
            entries.removeValue(forKey: cameraID)?.ingest.stop()
            let ingest = HTTPFLVIngest(url: url, configuration: sessionConfiguration)
            entries[cameraID] = Entry(url: url, ingest: ingest)
            ingest.start()
            changed = true
        }

        if changed {
            revision &+= 1
        }
    }

    func ingest(for cameraID: UUID) -> HTTPFLVIngest? {
        entries[cameraID]?.ingest
    }

    func stopAll() {
        for entry in entries.values {
            entry.ingest.stop()
        }
        if !entries.isEmpty {
            entries.removeAll()
            revision &+= 1
        }
    }
}
