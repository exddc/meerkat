import Foundation
import SQLite3
import SwiftData

struct LegacyCamera {
    var cameraID: UUID
    var name: String
    var streamURLString: String
    var authenticationRequired: Bool?
    var requiresAddressChange: Bool?
    var isVisible: Bool
}

enum LegacyCameraStore {
    static let url = URL.applicationSupportDirectory.appending(path: "default.store")
    static let importCompletedKey = "legacyCameraImportCompleted"

    struct ReadError: Error {
        let message: String
    }

    @MainActor
    static func importIfNeeded(
        from url: URL = url,
        into context: ModelContext,
        defaults: UserDefaults = .standard
    ) throws {
        guard !defaults.bool(forKey: importCompletedKey) else { return }

        let existingCameras = try context.fetch(FetchDescriptor<Camera>())
        let existingIDs = Set(existingCameras.map(\.cameraID))
        let firstSortIndex = (existingCameras.map(\.sortIndex).max() ?? -1) + 1
        let newCameras = try readCameras(at: url).filter { !existingIDs.contains($0.cameraID) }

        for (offset, legacy) in newCameras.enumerated() {
            let camera = Camera(
                name: legacy.name,
                streamURLString: legacy.streamURLString,
                sortIndex: firstSortIndex + offset,
                isVisible: legacy.isVisible,
                cameraID: legacy.cameraID
            )
            camera.authenticationRequired = legacy.authenticationRequired
            camera.requiresAddressChange = legacy.requiresAddressChange
            context.insert(camera)
        }
        try Persistence.save(context)
        defaults.set(true, forKey: importCompletedKey)
    }

    /// Reads with plain read-only SQLite so the shared store is never migrated.
    static func readCameras(at url: URL) throws -> [LegacyCamera] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ReadError(message: errorMessage(database))
        }
        sqlite3_busy_timeout(database, 2_000)

        let columns = try columnNames(of: "ZCAMERA", in: database)
        guard columns.contains("ZNAME"), columns.contains("ZSTREAMURLSTRING") else { return [] }

        let selected = [
            "ZCAMERAID", "ZNAME", "ZSTREAMURLSTRING", "ZAUTHENTICATIONREQUIRED",
            "ZREQUIRESADDRESSCHANGE", "ZISVISIBLE",
        ].map { columns.contains($0) ? $0 : "NULL" }
        let order = columns.contains("ZSORTINDEX") ? "ZSORTINDEX, Z_PK" : "Z_PK"
        let statement = try prepare(
            "SELECT \(selected.joined(separator: ", ")) FROM ZCAMERA ORDER BY \(order)",
            in: database
        )
        defer { sqlite3_finalize(statement) }

        var cameras: [LegacyCamera] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                cameras.append(
                    LegacyCamera(
                        cameraID: uuid(statement, 0) ?? UUID(),
                        name: text(statement, 1) ?? "",
                        streamURLString: text(statement, 2) ?? "",
                        authenticationRequired: bool(statement, 3),
                        requiresAddressChange: bool(statement, 4),
                        isVisible: bool(statement, 5) ?? true
                    )
                )
            case SQLITE_DONE:
                return cameras
            default:
                throw ReadError(message: errorMessage(database))
            }
        }
    }

    private static func columnNames(of table: String, in database: OpaquePointer?) throws -> Set<String> {
        let statement = try prepare("PRAGMA table_info(\(table))", in: database)
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let name = text(statement, 1) { names.insert(name) }
            case SQLITE_DONE:
                return names
            default:
                throw ReadError(message: errorMessage(database))
            }
        }
    }

    private static func prepare(_ sql: String, in database: OpaquePointer?) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ReadError(message: errorMessage(database))
        }
        return statement
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }

    private static func bool(_ statement: OpaquePointer?, _ index: Int32) -> Bool? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index) != 0
    }

    private static func uuid(_ statement: OpaquePointer?, _ index: Int32) -> UUID? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_BLOB where sqlite3_column_bytes(statement, index) == 16:
            guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
            return UUID(uuid: bytes.loadUnaligned(as: uuid_t.self))
        case SQLITE_TEXT:
            return text(statement, index).flatMap(UUID.init(uuidString:))
        default:
            return nil
        }
    }

    private static func errorMessage(_ database: OpaquePointer?) -> String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open legacy store"
    }
}
