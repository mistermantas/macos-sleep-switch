import Foundation
import SQLite3

/// Mirrors the Codex desktop catalog from its own local databases. This is a
/// read-only presentation adapter: titles, previews, sections and a few local
/// message excerpts stay in memory for the current Operator window only.
/// Nothing here is written to Operator.sqlite or sent through CloudKit.
struct CodexThreadMirrorAdapter {
    let stateDatabaseURL: URL
    let historyDatabaseURL: URL
    let maximumThreads: Int

    init(
        stateDatabaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite"),
        historyDatabaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/thread_history_1.sqlite"),
        maximumThreads: Int = 180
    ) {
        self.stateDatabaseURL = stateDatabaseURL
        self.historyDatabaseURL = historyDatabaseURL
        self.maximumThreads = max(1, maximumThreads)
    }

    func snapshot() -> CodexMirrorSnapshot {
        guard FileManager.default.fileExists(atPath: stateDatabaseURL.path) else {
            return .unavailable
        }
        guard let state = openReadOnly(stateDatabaseURL) else {
            return CodexMirrorSnapshot(isAvailable: false, threads: [], issue: "Codex catalog is unavailable.")
        }
        defer { sqlite3_close(state) }
        let history = openReadOnly(historyDatabaseURL)
        defer { if let history { sqlite3_close(history) } }

        let sql = """
        SELECT t.id, COALESCE(NULLIF(TRIM(t.name), ''), t.title), t.preview, t.first_user_message, t.cwd,
               t.archived, t.is_pinned, t.thread_section_id, s.name,
               t.section_position, p.name, t.recency_at_ms
        FROM threads t
        LEFT JOIN thread_sections s ON s.id = t.thread_section_id
        LEFT JOIN projects p ON p.id = t.project_id
        WHERE t.preview <> ''
        ORDER BY t.archived ASC, t.is_pinned DESC, t.recency_at_ms DESC
        LIMIT ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(state, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return CodexMirrorSnapshot(isAvailable: false, threads: [], issue: "Codex catalog format changed.")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(maximumThreads))

        var threads: [CodexThreadMirror] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = text(statement, 0)
            guard !id.isEmpty else { continue }
            let latestTurn = history.flatMap { latestTurn(for: id, database: $0) }
            let completedAt = latestTurn?.completedAt
            let threadStatus = status(latestTurn?.status, completedAt: completedAt)
            let messages = history.map { recentMessages(for: id, database: $0) } ?? []
            let recentActivity = threadStatus == .running
                ? history.flatMap { recentActivity(for: id, database: $0) }
                : nil
            threads.append(CodexThreadMirror(
                id: id,
                title: nonEmpty(text(statement, 1), fallback: nonEmpty(text(statement, 3), fallback: "Untitled chat")),
                preview: nonEmpty(text(statement, 2), fallback: text(statement, 3)),
                cwd: text(statement, 4),
                projectName: optionalText(statement, 10),
                sectionID: optionalText(statement, 7),
                sectionName: optionalText(statement, 8),
                sectionPosition: optionalInt(statement, 9),
                isPinned: sqlite3_column_int(statement, 6) != 0,
                isArchived: sqlite3_column_int(statement, 5) != 0,
                status: threadStatus,
                latestTurnErrorCode: latestTurn.flatMap(errorCode),
                updatedAt: date(statement, 11) ?? Date.distantPast,
                startedAt: latestTurn?.startedAt,
                completedAt: completedAt,
                messages: messages,
                recentActivity: recentActivity
            ))
        }
        return CodexMirrorSnapshot(isAvailable: true, threads: threads, issue: nil)
    }

    private func recentMessages(for threadID: String, database: OpaquePointer) -> [CodexThreadMessage] {
        let sql = """
        SELECT item_id, item_type, item_json, created_at_ms
        FROM thread_items
        WHERE thread_id = ? AND item_type IN ('userMessage', 'agentMessage')
        ORDER BY rollout_ordinal DESC LIMIT 4;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, threadID)
        var messages: [CodexThreadMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let kind = text(statement, 1)
            let role: CodexThreadMessage.Role
            switch kind {
            case "userMessage": role = .user
            case "agentMessage": role = .agent
            default: continue
            }
            guard let body = messageText(text(statement, 2)), !body.isEmpty else { continue }
            messages.append(CodexThreadMessage(
                id: text(statement, 0),
                role: role,
                text: body,
                createdAt: date(statement, 3) ?? Date.distantPast
            ))
        }
        return messages.reversed()
    }

    private func latestTurn(
        for threadID: String,
        database: OpaquePointer
    ) -> (status: String?, errorJSON: String?, startedAt: Date?, completedAt: Date?)? {
        let sql = """
        SELECT status, error_json, started_at, completed_at
        FROM thread_turns
        WHERE thread_id = ?
        ORDER BY rollout_ordinal DESC LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, threadID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return (
            optionalText(statement, 0),
            optionalText(statement, 1),
            optionalDate(statement, 2),
            optionalDate(statement, 3)
        )
    }

    /// Reads only stable item type/status metadata for an in-progress turn.
    /// The command/tool body, output, file path, and message content are never
    /// decoded into this activity category.
    private func recentActivity(
        for threadID: String,
        database: OpaquePointer
    ) -> CompanionWorkActivity? {
        let sql = """
        SELECT item_type, item_json
        FROM thread_items
        WHERE thread_id = ?
          AND item_type IN ('reasoning', 'commandExecution', 'fileChange', 'mcpToolCall', 'dynamicToolCall', 'webSearch')
        ORDER BY rollout_ordinal DESC LIMIT 8;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, threadID)

        var fallback: CompanionWorkActivity?
        while sqlite3_step(statement) == SQLITE_ROW {
            let type = text(statement, 0)
            switch type {
            case "commandExecution":
                if commandIsRunning(text(statement, 1)) { return .commandRunning }
                fallback = fallback ?? .commandFinished
            case "fileChange":
                fallback = fallback ?? .editingFiles
            case "mcpToolCall", "dynamicToolCall":
                fallback = fallback ?? .usingTool
            case "webSearch":
                fallback = fallback ?? .webSearch
            case "reasoning":
                fallback = fallback ?? .reasoning
            default:
                continue
            }
        }
        return fallback
    }

    private func commandIsRunning(_ raw: String) -> Bool {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let status = dictionary["status"] as? String else {
            return false
        }
        let normalized = status.lowercased()
        return normalized.contains("progress") || normalized.contains("running")
    }

    private func errorCode(from latestTurn: (
        status: String?,
        errorJSON: String?,
        startedAt: Date?,
        completedAt: Date?
    )) -> String? {
        guard let raw = latestTurn.errorJSON,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        if let text = dictionary["codexErrorInfo"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return nil
    }

    private func messageText(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        let candidate = textValue(dictionary["text"])
            ?? textValue(dictionary["content"])
            ?? textValue(dictionary["message"])
        guard let candidate else { return nil }
        let compact = candidate
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(compact.prefix(360))
    }

    private func textValue(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let values = value as? [Any] {
            return values.compactMap(textValue).joined(separator: " ")
        }
        if let dictionary = value as? [String: Any] {
            return textValue(dictionary["text"]) ?? textValue(dictionary["content"])
        }
        return nil
    }

    private func status(_ raw: String?, completedAt: Date?) -> CodexThreadStatus {
        let value = raw?.lowercased() ?? ""
        if value.contains("running") || value.contains("progress") || value.contains("active") { return .running }
        if value.contains("abort") || value.contains("cancel") || value.contains("stop") || value.contains("fail") || value.contains("interrupt") || value.contains("error") { return .stopped }
        if value.contains("complete") || value.contains("finish") || completedAt != nil { return .finished }
        if value.contains("wait") || value.contains("queue") { return .waiting }
        return .unknown
    }

    private func openReadOnly(_ url: URL) -> OpaquePointer? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        sqlite3_busy_timeout(database, 700)
        return database
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func optionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : text(statement, index)
    }

    private func optionalInt(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, index))
    }

    private func date(_ statement: OpaquePointer, _ index: Int32) -> Date? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : date(from: sqlite3_column_int64(statement, index))
    }

    private func optionalDate(_ statement: OpaquePointer, _ index: Int32) -> Date? { date(statement, index) }

    private func date(from value: Int64) -> Date {
        let seconds = value > 100_000_000_000 ? Double(value) / 1_000 : Double(value)
        return Date(timeIntervalSince1970: seconds)
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func nonEmpty(_ value: String, fallback: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : value
    }
}
