import Foundation
import SQLite3

enum CodexThreadSectionError: LocalizedError {
    case unavailable
    case openFailed(String)
    case updateFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Moving Codex chats is unavailable in this build."
        case .openFailed(let message), .updateFailed(let message): message
        }
    }
}

/// Updates only Codex's sidebar assignment fields after an explicit drag in
/// Operator. This is deliberately unavailable in the sandboxed App Store
/// build: its `.codex` bookmark is read-only. The direct build uses a short
/// SQLite transaction and leaves titles, messages, projects, pins, and all
/// other Codex state untouched.
struct CodexThreadSectionController {
    let stateDatabaseURL: URL

    init(stateDatabaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/state_5.sqlite")) {
        self.stateDatabaseURL = stateDatabaseURL
    }

    func move(threadID: String, toSectionID sectionID: String?) throws {
#if APP_STORE
        throw CodexThreadSectionError.unavailable
#else
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            stateDatabaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw CodexThreadSectionError.openFailed("Codex’s local sidebar database is unavailable.")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)

        guard sqlite3_exec(database, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            throw CodexThreadSectionError.updateFailed("Codex is busy updating its sidebar. Try again in a moment.")
        }
        do {
            let sql = """
            UPDATE threads
            SET thread_section_id = ?,
                section_position = (
                    SELECT COALESCE(MAX(section_position), -1) + 1
                    FROM threads WHERE thread_section_id IS ?
                )
            WHERE id = ?;
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw CodexThreadSectionError.updateFailed(String(cString: sqlite3_errmsg(database)))
            }
            defer { sqlite3_finalize(statement) }
            if let sectionID {
                sqlite3_bind_text(statement, 1, sectionID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                sqlite3_bind_text(statement, 2, sectionID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            } else {
                sqlite3_bind_null(statement, 1)
                sqlite3_bind_null(statement, 2)
            }
            sqlite3_bind_text(statement, 3, threadID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw CodexThreadSectionError.updateFailed(String(cString: sqlite3_errmsg(database)))
            }
            guard sqlite3_changes(database) == 1 else {
                throw CodexThreadSectionError.updateFailed("That Codex chat is no longer available.")
            }
            guard sqlite3_exec(database, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                throw CodexThreadSectionError.updateFailed(String(cString: sqlite3_errmsg(database)))
            }
        } catch {
            _ = sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            throw error
        }
#endif
    }
}
