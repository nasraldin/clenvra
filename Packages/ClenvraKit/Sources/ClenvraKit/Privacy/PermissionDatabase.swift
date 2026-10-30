import Foundation
import SQLite3

/// Reads macOS's privacy (TCC) database read-only. macOS protects it behind Full Disk Access, so a failure to open it
/// means "cannot tell", never "no permissions".
public enum PermissionDatabase {
    public enum Error: Swift.Error, Equatable {
        /// The file is absent, locked, protected, or not a database.
        case unreadable
    }

    /// Every grant in the database, allowed or not. Rows with a missing service or client are skipped.
    public static func read(at path: String, scope: PermissionGrant.Scope) throws(PermissionDatabase.Error)
        -> [PermissionGrant]
    {
        var database: OpaquePointer?
        // Closing also covers a handle returned with an error from open.
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            throw .unreadable
        }
        sqlite3_busy_timeout(database, 1_000)

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = "SELECT service, client, client_type, auth_value, last_modified FROM access"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw .unreadable
        }

        var grants: [PermissionGrant] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            // A read that fails partway gives no list at all rather than a partial one.
            guard step == SQLITE_ROW else { throw .unreadable }
            guard let service = text(statement, 0), let client = text(statement, 1) else { continue }
            let authValue = sqlite3_column_int64(statement, 3)
            let modified =
                sqlite3_column_type(statement, 4) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 4)))
            grants.append(
                PermissionGrant(
                    service: service, client: client, clientIsBundleID: sqlite3_column_int64(statement, 2) == 0,
                    isAllowed: authValue == 2 || authValue == 3, lastModified: modified, scope: scope))
        }
        return grants
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
            let value = sqlite3_column_text(statement, column)
        else { return nil }
        let string = String(cString: value)
        return string.isEmpty ? nil : string
    }
}
