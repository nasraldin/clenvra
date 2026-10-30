import Foundation
import SQLite3

/// Writes a small permissions database with the columns of macOS's `TCC.db` `access` table, for read tests.
enum TCCFixture {
    struct Row {
        let service: String
        let client: String
        let clientType: Int
        let authValue: Int
        var lastModified: Int? = nil
    }

    struct Failure: Error {
        let message: String
    }

    static func write(_ rows: [Row], to path: String) throws {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw Failure(message: "open \(path)")
        }
        try execute(
            """
            CREATE TABLE IF NOT EXISTS access (service TEXT, client TEXT, client_type INTEGER, auth_value INTEGER,
            auth_reason INTEGER, last_modified INTEGER)
            """, in: database)
        for row in rows {
            let modified = row.lastModified.map(String.init) ?? "NULL"
            try execute(
                """
                INSERT INTO access VALUES ('\(row.service)', '\(row.client)', \(row.clientType), \(row.authValue), 0,
                \(modified))
                """, in: database)
        }
    }

    /// Removes a grant, as `tccutil reset` would.
    static func remove(service: String, client: String, from path: String) throws {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw Failure(message: "open \(path)")
        }
        try execute("DELETE FROM access WHERE service = '\(service)' AND client = '\(client)'", in: database)
    }

    private static func execute(_ sql: String, in database: OpaquePointer?) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw Failure(message: sql) }
    }
}
