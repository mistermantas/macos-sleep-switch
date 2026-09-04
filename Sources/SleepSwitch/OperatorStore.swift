import Foundation
import SQLite3

enum OperatorStoreError: LocalizedError {
    case couldNotOpen(URL, String)
    case statementFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .couldNotOpen(let url, let message):
            return "Operator could not open its local database at \(url.path). \(message)"
        case .statementFailed(_, let message):
            return "Operator could not update its local database. \(message)"
        }
    }
}

/// The only persistent home for Operator-derived history and skill metadata.
/// It never stores source JSON, prompts, message/tool content, or raw skill
/// text. Source files remain read-only inputs.
final class OperatorStore {
    static let defaultDatabaseName = "Operator.sqlite"

    let databaseURL: URL
    private var database: OpaquePointer?
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL = OperatorStore.defaultDatabaseURL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &opened,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let opened else {
            let message = opened.map(Self.errorMessage) ?? "SQLite could not open the database."
            if let opened { sqlite3_close(opened) }
            throw OperatorStoreError.couldNotOpen(databaseURL, message)
        }
        database = opened
        sqlite3_busy_timeout(opened, 1_000)
        do {
            try createSchema()
        } catch {
            sqlite3_close(opened)
            database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    static var defaultDatabaseURL: URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return root
            .appendingPathComponent("Sleep Switch", isDirectory: true)
            .appendingPathComponent(defaultDatabaseName)
    }

    func ingest(_ snapshot: OperatorAdapterSnapshot) throws {
        try transaction { [self] in
            for session in snapshot.sessions { try save(session) }
            for event in snapshot.events { try save(event) }
        }
    }

    func upsertSkills(_ skills: [OperatorSkill]) throws {
        try transaction { [self] in
            for skill in skills {
                try run("""
                INSERT INTO operator_skills (id, source_url, name, source_group, fingerprint, modified_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    source_url = excluded.source_url,
                    name = excluded.name,
                    source_group = excluded.source_group,
                    fingerprint = excluded.fingerprint,
                    modified_at = excluded.modified_at;
                """) { [self] statement in
                    bindText(statement, 1, skill.id)
                    bindText(statement, 2, skill.sourceURL.path)
                    bindText(statement, 3, skill.name)
                    bindText(statement, 4, skill.sourceGroup)
                    bindText(statement, 5, skill.fingerprint)
                    bindDouble(statement, 6, skill.modifiedAt.timeIntervalSince1970)
                }
            }
        }
    }

    func setFavourite(_ isFavourite: Bool, for skillID: String) throws {
        try run("""
        INSERT INTO operator_skill_metadata (skill_id, is_favourite) VALUES (?, ?)
        ON CONFLICT(skill_id) DO UPDATE SET is_favourite = excluded.is_favourite;
        """) { [self] in
            bindText($0, 1, skillID)
            bindInt($0, 2, isFavourite ? 1 : 0)
        }
    }

    func replaceTags(_ tags: [String], for skillID: String) throws {
        let normalized = Array(Set(tags.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
        try transaction { [self] in
            try run("DELETE FROM operator_skill_tags WHERE skill_id = ?;") { [self] in
                bindText($0, 1, skillID)
            }
            for tag in normalized {
                try run("INSERT INTO operator_skill_tags (skill_id, tag) VALUES (?, ?);") { [self] in
                    bindText($0, 1, skillID)
                    bindText($0, 2, tag)
                }
            }
        }
    }

    func recordSkillUse(_ event: SkillUseEvent) throws {
        try run("""
        INSERT OR IGNORE INTO operator_skill_use_events
            (id, skill_id, session_id, harness_id, occurred_at)
        VALUES (?, ?, ?, ?, ?);
        """) { [self] in
            bindText($0, 1, event.id)
            bindText($0, 2, event.skillID)
            bindOptionalText($0, 3, event.sessionID)
            bindOptionalText($0, 4, event.harnessID)
            bindDouble($0, 5, event.occurredAt.timeIntervalSince1970)
        }
    }

    /// A local workflow label is Operator-owned metadata for a Codex thread.
    /// It stores only the opaque thread ID and lane—not a title, message,
    /// source path, or a mutation of Codex's own database.
    func threadWorkflowLanes() throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try query(
            "SELECT thread_id, lane FROM operator_thread_workflow;"
        ) { [self] in (text($0, 0), text($0, 1)) })
    }

    func setThreadWorkflowLane(_ lane: String, threadID: String) throws {
        try run("""
        INSERT INTO operator_thread_workflow (thread_id, lane, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(thread_id) DO UPDATE SET
            lane = excluded.lane,
            updated_at = excluded.updated_at;
        """) { [self] in
            bindText($0, 1, threadID)
            bindText($0, 2, lane)
            bindDouble($0, 3, Date().timeIntervalSince1970)
        }
    }

    func sessions(limit: Int = 200) throws -> [OperatorSession] {
        try query("""
        SELECT id, harness_id, harness_name, state, started_at, ended_at,
               last_activity_at, input_tokens, output_tokens, reasoning_tokens, cached_tokens
        FROM operator_sessions ORDER BY COALESCE(last_activity_at, started_at) DESC LIMIT ?;
        """, bind: { [self] in bindInt($0, 1, max(1, limit)) }) { [self] statement in
            OperatorSession(
                id: text(statement, 0),
                harnessID: text(statement, 1),
                harnessName: text(statement, 2),
                state: OperatorSessionState(rawValue: text(statement, 3)) ?? .unknown,
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                endedAt: optionalDate(statement, 5),
                lastActivityAt: optionalDate(statement, 6),
                inputTokens: int(statement, 7),
                outputTokens: int(statement, 8),
                reasoningTokens: int(statement, 9),
                cachedTokens: int(statement, 10)
            )
        }
    }

    func skillRecords() throws -> [OperatorSkillRecord] {
        let skills = try query("""
        SELECT s.id, s.source_url, s.name, s.source_group, s.fingerprint, s.modified_at,
               COALESCE(m.is_favourite, 0),
               (SELECT COUNT(*) FROM operator_skill_use_events u WHERE u.skill_id = s.id)
        FROM operator_skills s
        LEFT JOIN operator_skill_metadata m ON m.skill_id = s.id
        ORDER BY lower(s.name) ASC;
        """) { [self] statement in
            (
                OperatorSkill(
                    id: text(statement, 0),
                    sourceURL: URL(fileURLWithPath: text(statement, 1)),
                    name: text(statement, 2),
                    sourceGroup: text(statement, 3),
                    fingerprint: text(statement, 4),
                    modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                ),
                sqlite3_column_int(statement, 6) != 0,
                int(statement, 7)
            )
        }
        let tags = try allTags()
        return skills.map { skill, favourite, useCount in
            OperatorSkillRecord(
                skill: skill,
                metadata: OperatorSkillMetadata(
                    skillID: skill.id,
                    isFavourite: favourite,
                    tags: tags[skill.id] ?? []
                ),
                useCount: useCount
            )
        }
    }

    private func save(_ session: OperatorSession) throws {
        try run("""
        INSERT INTO operator_sessions
            (id, harness_id, harness_name, state, started_at, ended_at, last_activity_at,
             input_tokens, output_tokens, reasoning_tokens, cached_tokens)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            state = excluded.state,
            ended_at = excluded.ended_at,
            last_activity_at = excluded.last_activity_at,
            input_tokens = excluded.input_tokens,
            output_tokens = excluded.output_tokens,
            reasoning_tokens = excluded.reasoning_tokens,
            cached_tokens = excluded.cached_tokens;
        """) { [self] in
            bindText($0, 1, session.id)
            bindText($0, 2, session.harnessID)
            bindText($0, 3, session.harnessName)
            bindText($0, 4, session.state.rawValue)
            bindDouble($0, 5, session.startedAt.timeIntervalSince1970)
            bindOptionalDouble($0, 6, session.endedAt?.timeIntervalSince1970)
            bindOptionalDouble($0, 7, session.lastActivityAt?.timeIntervalSince1970)
            bindInt($0, 8, session.inputTokens)
            bindInt($0, 9, session.outputTokens)
            bindInt($0, 10, session.reasoningTokens)
            bindInt($0, 11, session.cachedTokens)
        }
    }

    private func save(_ event: OperatorEvent) throws {
        try run("""
        INSERT OR IGNORE INTO operator_events (id, session_id, harness_id, kind, occurred_at)
        VALUES (?, ?, ?, ?, ?);
        """) { [self] in
            bindText($0, 1, event.id)
            bindText($0, 2, event.sessionID)
            bindText($0, 3, event.harnessID)
            bindText($0, 4, event.kind.rawValue)
            bindDouble($0, 5, event.occurredAt.timeIntervalSince1970)
        }
    }

    private func allTags() throws -> [String: [String]] {
        let rows = try query(
            "SELECT skill_id, tag FROM operator_skill_tags ORDER BY lower(tag) ASC;"
        ) { [self] in (text($0, 0), text($0, 1)) }
        return Dictionary(grouping: rows, by: \ .0).mapValues { $0.map(\.1) }
    }

    private func createSchema() throws {
        try run("PRAGMA journal_mode = WAL;")
        try run("PRAGMA synchronous = NORMAL;")
        try run("""
        CREATE TABLE IF NOT EXISTS operator_sessions (
            id TEXT PRIMARY KEY, harness_id TEXT NOT NULL, harness_name TEXT NOT NULL,
            state TEXT NOT NULL, started_at REAL NOT NULL, ended_at REAL,
            last_activity_at REAL, input_tokens INTEGER NOT NULL, output_tokens INTEGER NOT NULL,
            reasoning_tokens INTEGER NOT NULL, cached_tokens INTEGER NOT NULL
        );
        """)
        try run("CREATE INDEX IF NOT EXISTS operator_sessions_activity ON operator_sessions(last_activity_at DESC);")
        try run("""
        CREATE TABLE IF NOT EXISTS operator_events (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL, harness_id TEXT NOT NULL,
            kind TEXT NOT NULL, occurred_at REAL NOT NULL
        );
        """)
        try run("""
        CREATE TABLE IF NOT EXISTS operator_skills (
            id TEXT PRIMARY KEY, source_url TEXT NOT NULL, name TEXT NOT NULL,
            source_group TEXT NOT NULL, fingerprint TEXT NOT NULL, modified_at REAL NOT NULL
        );
        """)
        try run("""
        CREATE TABLE IF NOT EXISTS operator_skill_metadata (
            skill_id TEXT PRIMARY KEY, is_favourite INTEGER NOT NULL DEFAULT 0
        );
        """)
        try run("""
        CREATE TABLE IF NOT EXISTS operator_skill_tags (
            skill_id TEXT NOT NULL, tag TEXT NOT NULL,
            PRIMARY KEY (skill_id, tag)
        );
        """)
        try run("""
        CREATE TABLE IF NOT EXISTS operator_skill_use_events (
            id TEXT PRIMARY KEY, skill_id TEXT NOT NULL, session_id TEXT,
            harness_id TEXT, occurred_at REAL NOT NULL
        );
        """)
        try run("""
        CREATE TABLE IF NOT EXISTS operator_thread_workflow (
            thread_id TEXT PRIMARY KEY, lane TEXT NOT NULL, updated_at REAL NOT NULL
        );
        """)
    }

    private func transaction(_ work: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE;")
        do {
            try work()
            try run("COMMIT;")
        } catch {
            try? run("ROLLBACK;")
            throw error
        }
    }

    private func run(_ sql: String, bind: ((OpaquePointer) -> Void)? = nil) throws {
        guard let database else { throw OperatorStoreError.statementFailed(sql, "Database unavailable.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw OperatorStoreError.statementFailed(sql, Self.errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        bind?(statement)
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else {
            throw OperatorStoreError.statementFailed(sql, Self.errorMessage(database))
        }
    }

    private func query<T>(
        _ sql: String,
        bind: ((OpaquePointer) -> Void)? = nil,
        map: (OpaquePointer) -> T
    ) throws -> [T] {
        guard let database else { throw OperatorStoreError.statementFailed(sql, "Database unavailable.") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw OperatorStoreError.statementFailed(sql, Self.errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        bind?(statement)
        var values: [T] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            values.append(map(statement))
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else {
            throw OperatorStoreError.statementFailed(sql, Self.errorMessage(database))
        }
        return values
    }

    private func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) }
    }
    private func bindOptionalText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        bindText(statement, index, value)
    }
    private func bindInt(_ statement: OpaquePointer, _ index: Int32, _ value: Int) {
        sqlite3_bind_int64(statement, index, sqlite3_int64(value))
    }
    private func bindDouble(_ statement: OpaquePointer, _ index: Int32, _ value: Double) {
        sqlite3_bind_double(statement, index, value)
    }
    private func bindOptionalDouble(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        bindDouble(statement, index, value)
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
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }
    private static func errorMessage(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }
}
