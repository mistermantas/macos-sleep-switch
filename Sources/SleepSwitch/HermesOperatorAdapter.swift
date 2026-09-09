import Foundation
import SQLite3

/// Hermes exposes rich counters in its local `sessions` table. This adapter
/// opens that database read-only and intentionally never queries `messages`,
/// FTS tables, titles, paths, prompts, or any other sensitive columns.
struct HermesOperatorAdapter: OperatorAdapter {
    let harnessID = "hermes-agent"
    let harnessName = "Hermes"
    let databaseURL: URL
    let now: () -> Date
    /// An unclosed row is not necessarily live: interrupted Hermes sessions
    /// can be left without `ended_at`. Treat it as live only while it is still
    /// receiving activity, so stale local data never impersonates an agent.
    let activeWindow: TimeInterval

    init(
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/state.db"),
        activeWindow: TimeInterval = 120,
        now: @escaping () -> Date = Date.init
    ) {
        self.databaseURL = databaseURL
        self.activeWindow = max(30, activeWindow)
        self.now = now
    }

    func snapshot() -> OperatorAdapterSnapshot {
        let refreshedAt = now()
        let capabilities = [
            HarnessCapability(harnessID: harnessID, kind: .sessions, isSupported: true),
            HarnessCapability(harnessID: harnessID, kind: .sessionHistory, isSupported: true),
            HarnessCapability(harnessID: harnessID, kind: .tokenUsage, isSupported: true)
        ]
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return result(.unavailable, refreshedAt, capabilities,
                          issue: "Hermes session history hasn't been created on this Mac yet.")
        }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let failure = databaseFailure(openResult, database, refreshedAt, capabilities)
            if let database { sqlite3_close(database) }
            return failure
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)

        let sql = """
        SELECT id, source, started_at, ended_at, last_activity_at,
               input_tokens, output_tokens, cache_read_tokens,
               cache_write_tokens, reasoning_tokens
        FROM sessions
        ORDER BY COALESCE(last_activity_at, started_at) DESC
        LIMIT 500;
        """
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK,
              let statement else {
            let failure = databaseFailure(prepareResult, database, refreshedAt, capabilities)
            sqlite3_finalize(statement)
            return failure
        }
        defer { sqlite3_finalize(statement) }

        var sessions: [OperatorSession] = []
        var events: [OperatorEvent] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            defer { stepResult = sqlite3_step(statement) }
            let id = text(statement, 0)
            guard !id.isEmpty else { continue }
            let startedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let endedAt = optionalDate(statement, 3)
            let lastActivityAt = optionalDate(statement, 4)
            let activity = lastActivityAt ?? startedAt
            let isActivelyUpdating = refreshedAt.timeIntervalSince(activity) <= activeWindow
            let state: OperatorSessionState = endedAt == nil && isActivelyUpdating
                ? .running
                : .finished
            let session = OperatorSession(
                id: id,
                harnessID: harnessID,
                harnessName: harnessName,
                state: state,
                startedAt: startedAt,
                endedAt: endedAt,
                lastActivityAt: lastActivityAt,
                inputTokens: int(statement, 5),
                outputTokens: int(statement, 6),
                reasoningTokens: int(statement, 9),
                cachedTokens: int(statement, 7) + int(statement, 8)
            )
            sessions.append(session)
            events.append(OperatorEvent(
                id: "\(id):started",
                sessionID: id,
                harnessID: harnessID,
                kind: .sessionStarted,
                occurredAt: startedAt
            ))
            if let endedAt {
                events.append(OperatorEvent(
                    id: "\(id):finished",
                    sessionID: id,
                    harnessID: harnessID,
                    kind: .sessionFinished,
                    occurredAt: endedAt
                ))
            }
        }
        guard stepResult == SQLITE_DONE else {
            return databaseFailure(stepResult, database, refreshedAt, capabilities)
        }
        return OperatorAdapterSnapshot(
            harnessID: harnessID,
            harnessName: harnessName,
            availability: .available,
            refreshedAt: refreshedAt,
            capabilities: capabilities,
            sessions: sessions,
            events: events
        )
    }

    private func result(
        _ availability: OperatorAvailability,
        _ refreshedAt: Date,
        _ capabilities: [HarnessCapability],
        issue: String? = nil,
        diagnostic: String? = nil
    ) -> OperatorAdapterSnapshot {
        OperatorAdapterSnapshot(
            harnessID: harnessID,
            harnessName: harnessName,
            availability: availability,
            refreshedAt: refreshedAt,
            capabilities: capabilities,
            sessions: [],
            events: [],
            issue: issue,
            diagnostic: diagnostic
        )
    }

    private func databaseFailure(
        _ code: Int32,
        _ database: OpaquePointer?,
        _ refreshedAt: Date,
        _ capabilities: [HarnessCapability]
    ) -> OperatorAdapterSnapshot {
        // Extended SQLite result codes retain their primary code in the low byte.
        // A busy writer or an unsupported schema does not mean the data is corrupt.
        let availability: OperatorAvailability
        let issue: String
        switch code & 0xff {
        case SQLITE_BUSY, SQLITE_LOCKED:
            availability = .unavailable
            issue = "Hermes database is busy. Sleep Switch will retry automatically."
        case SQLITE_PERM, SQLITE_AUTH:
            availability = .permissionRequired
            issue = "Sleep Switch needs read access to Hermes session history."
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            availability = .malformedSource
            issue = "Hermes session history could not be read."
        default:
            availability = .unavailable
            issue = "Sleep Switch couldn't read Hermes session history."
        }
        let message = database.map { String(cString: sqlite3_errmsg($0)) }
            ?? String(cString: sqlite3_errstr(code))
        return result(availability, refreshedAt, capabilities, issue: issue,
                      diagnostic: "SQLite \(code): \(message)")
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func int(_ statement: OpaquePointer, _ column: Int32) -> Int {
        max(0, Int(sqlite3_column_int64(statement, column)))
    }

    private func optionalDate(_ statement: OpaquePointer, _ column: Int32) -> Date? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }
}
