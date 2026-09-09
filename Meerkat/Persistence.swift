import Foundation
import SwiftData

enum Persistence {
    static let schema = Schema([Camera.self])

    static let container: ModelContainer = {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }()

    @MainActor
    static func cameraIngestConfigurations() -> [CameraIngestConfiguration] {
        let descriptor = FetchDescriptor<Camera>(sortBy: [SortDescriptor(\Camera.sortIndex)])
        return (try? container.mainContext.fetch(descriptor))?.map(CameraIngestConfiguration.init) ?? []
    }

    @MainActor
    static func preview(
        cameras: [(name: String, url: String)] = [
            ("Camera 1", "https://camera.test/1"),
            ("Camera 2", "https://camera.test/2"),
            ("Camera 3", "https://camera.test/3"),
            ("Camera 4", "https://camera.test/4"),
        ]
    ) -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            for (index, camera) in cameras.enumerated() {
                container.mainContext.insert(
                    Camera(
                        name: camera.name,
                        streamURLString: camera.url,
                        sortIndex: index
                    )
                )
            }
            return container
        } catch {
            fatalError("Failed to create preview container: \(error)")
        }
    }
}
