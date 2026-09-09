import Foundation
import SQLite3

enum OperatorAdapterTests {
    static func run() {
        testCodexAdapterReadsOnlyNormalizedLifecycleAndTokenFields()
        testHermesAdapterReadsWhitelistedSessionCounters()
        testHermesBusyDatabaseRecoversWithoutClaimingCorruption()
        testHermesDatabaseErrorsKeepTheirActualCause()
        testOperatorStoreKeepsSkillMetadataOutOfSourceFiles()
    }

    private static func testCodexAdapterReadsOnlyNormalizedLifecycleAndTokenFields() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "sleep-switch-operator-codex-\(UUID().uuidString)",
            isDirectory: true
        )
        let sessions = root.appendingPathComponent("sessions/2026/09/04", isDirectory: true)
        let session = sessions.appendingPathComponent("rollout-operator-fixture.jsonl")
        let now = Date(timeIntervalSince1970: 1_788_500_000)
        defer { try? fileManager.removeItem(at: root) }

        do {
            try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
            try Data("""
            {"timestamp":"2026-09-04T10:00:00Z","type":"event_msg","payload":{"type":"task_started","text":"never keep this"}}
            {"timestamp":"2026-09-04T10:02:00Z","type":"event_msg","payload":{"type":"token_count","tokens_used":120,"message":"never keep this either"}}
            {"timestamp":"2026-09-04T10:05:00Z","type":"event_msg","payload":{"type":"task_complete","content":"private"}}
            """.utf8).write(to: session)
        } catch {
            fatalError("Test failed: could not create Operator Codex fixture: \(error)")
        }

        let snapshot = CodexOperatorAdapter(
            sessionsDirectory: root.appendingPathComponent("sessions"),
            now: { now }
        ).snapshot()
        expect(snapshot.availability == .available, "marks readable Codex logs available")
        expect(snapshot.sessions.count == 1, "normalizes one Codex rollout into one session")
        expect(snapshot.sessions.first?.state == .finished, "uses terminal lifecycle events")
        expect(snapshot.sessions.first?.inputTokens == 120, "keeps the whitelisted Codex tokens_used total")
        expect(snapshot.events.map(\.kind) == [.sessionFinished, .sessionStarted], "emits lifecycle events without record payloads")
        expect(
            !String(describing: snapshot).contains("never keep this"),
            "does not retain arbitrary Codex message fields"
        )
    }

    private static func testHermesAdapterReadsWhitelistedSessionCounters() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "sleep-switch-operator-hermes-\(UUID().uuidString)",
            isDirectory: true
        )
        let databaseURL = root.appendingPathComponent("state.db")
        defer { try? fileManager.removeItem(at: root) }

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            var database: OpaquePointer?
            guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
                fatalError("Test failed: could not create Hermes SQLite fixture")
            }
            defer { sqlite3_close(database) }
            let schema = """
            CREATE TABLE sessions (
              id TEXT PRIMARY KEY, source TEXT NOT NULL, started_at REAL NOT NULL,
              ended_at REAL, last_activity_at REAL, input_tokens INTEGER,
              output_tokens INTEGER, cache_read_tokens INTEGER,
              cache_write_tokens INTEGER, reasoning_tokens INTEGER,
              title TEXT, cwd TEXT, system_prompt TEXT
            );
            INSERT INTO sessions VALUES
              ('h-1', 'cli', 1000, NULL, 1100, 10, 20, 30, 40, 50,
               'private title', '/private/path', 'private prompt');
            """
            guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
                fatalError("Test failed: could not populate Hermes SQLite fixture")
            }
        } catch {
            fatalError("Test failed: could not prepare Hermes fixture: \(error)")
        }

        let snapshot = HermesOperatorAdapter(
            databaseURL: databaseURL,
            now: { Date(timeIntervalSince1970: 2_000) }
        ).snapshot()
        expect(snapshot.availability == .available, "marks readable Hermes session database available")
        expect(snapshot.sessions.count == 1, "reads Hermes sessions without messages")
        expect(snapshot.sessions.first?.state == .finished, "does not show a stale unclosed Hermes row as live")
        let liveSnapshot = HermesOperatorAdapter(
            databaseURL: databaseURL,
            now: { Date(timeIntervalSince1970: 1_160) }
        ).snapshot()
        expect(liveSnapshot.sessions.first?.state == .running, "keeps a recently active Hermes row live")
        expect(snapshot.sessions.first?.inputTokens == 10, "reads Hermes input counter")
        expect(snapshot.sessions.first?.outputTokens == 20, "reads Hermes output counter")
        expect(snapshot.sessions.first?.reasoningTokens == 50, "reads Hermes reasoning counter")
        expect(snapshot.sessions.first?.cachedTokens == 70, "combines Hermes cache counters")
        expect(
            !String(describing: snapshot).contains("private title"),
            "does not select Hermes title, path, or prompt columns"
        )
    }

    private static func testHermesBusyDatabaseRecoversWithoutClaimingCorruption() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-busy-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.db")
        var writer: OpaquePointer?
        expect(sqlite3_open(url.path, &writer) == SQLITE_OK, "creates locked Hermes fixture")
        defer { sqlite3_close(writer) }
        expect(sqlite3_exec(writer, """
            CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT, started_at REAL,
            ended_at REAL, last_activity_at REAL, input_tokens INTEGER, output_tokens INTEGER,
            cache_read_tokens INTEGER, cache_write_tokens INTEGER, reasoning_tokens INTEGER);
            INSERT INTO sessions VALUES ('h-1', 'cli', 1000, 1100, 1100, 10, 20, 0, 0, 0);
            BEGIN EXCLUSIVE;
            """, nil, nil, nil) == SQLITE_OK, "holds an exclusive Hermes writer transaction")
        let adapter = HermesOperatorAdapter(databaseURL: url)
        let busy = adapter.snapshot()
        expect(busy.availability == .unavailable,
               "a temporary database lock is unavailable, not malformed data")
        expect(busy.issue?.contains("retry automatically") == true,
               "explains that a temporary Hermes lock will be retried")
        expect(busy.diagnostic?.contains("database is locked") == true,
               "retains SQLite's actual failure for diagnosis")
        expect(sqlite3_exec(writer, "COMMIT;", nil, nil, nil) == SQLITE_OK, "releases writer lock")
        let recovered = adapter.snapshot()
        expect(recovered.availability == .available && recovered.sessions.count == 1,
               "automatically reads Hermes sessions once the writer releases its lock")
        expect(recovered.issue == nil && recovered.diagnostic == nil, "clears the error after recovery")
    }

    private static func testHermesDatabaseErrorsKeepTheirActualCause() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-errors-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.db")
        let adapter = HermesOperatorAdapter(databaseURL: url)

        let missing = adapter.snapshot()
        expect(missing.availability == .unavailable, "a missing Hermes database does not imply corruption")
        expect(!FileManager.default.fileExists(atPath: url.path), "reading absent Hermes history does not create it")

        var database: OpaquePointer?
        expect(sqlite3_open(url.path, &database) == SQLITE_OK, "creates an empty Hermes database")
        sqlite3_close(database)
        let empty = adapter.snapshot()
        expect(empty.availability == .unavailable, "a missing sessions table is not database corruption")
        expect(empty.diagnostic?.contains("no such table: sessions") == true, "preserves the schema error")

        let invalidData = Data("This is not a SQLite database.".utf8)
        try! invalidData.write(to: url)
        let unreadable = adapter.snapshot()
        expect(unreadable.availability == .malformedSource, "distinguishes genuinely unreadable database data")
        expect(unreadable.diagnostic?.contains("not a database") == true, "preserves the unreadable database error")
        expect(unreadable.sessions.isEmpty && unreadable.events.isEmpty, "does not report partial data as available")
        expect(try! Data(contentsOf: url) == invalidData, "does not modify Hermes source data while handling errors")
    }

    private static func testOperatorStoreKeepsSkillMetadataOutOfSourceFiles() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "sleep-switch-operator-store-\(UUID().uuidString)",
            isDirectory: true
        )
        let skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
        let skillDirectory = skillsRoot.appendingPathComponent("quiet-skill", isDirectory: true)
        let skillURL = skillDirectory.appendingPathComponent("SKILL.md")
        let databaseURL = root.appendingPathComponent("Operator.sqlite")
        let original = """
        ---
        name: Quiet Skill
        ---
        # Quiet Skill
        This content is an input, never a metadata target.
        """
        defer { try? fileManager.removeItem(at: root) }

        do {
            try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
            try Data(original.utf8).write(to: skillURL)
            let indexed = OperatorSkillIndexer(sources: [
                .init(url: skillsRoot, label: "Test skills")
            ]).index()
            expect(indexed.count == 1 && indexed[0].name == "Quiet Skill", "indexes SKILL.md metadata")

            let store = try OperatorStore(databaseURL: databaseURL)
            let session = OperatorSession(
                id: "session-1",
                harnessID: "codex",
                harnessName: "Codex",
                state: .running,
                startedAt: Date(timeIntervalSince1970: 100),
                endedAt: nil,
                lastActivityAt: Date(timeIntervalSince1970: 120),
                inputTokens: 12,
                outputTokens: 4,
                reasoningTokens: 3,
                cachedTokens: 2
            )
            try store.ingest(OperatorAdapterSnapshot(
                harnessID: "codex",
                harnessName: "Codex",
                availability: .available,
                refreshedAt: Date(timeIntervalSince1970: 120),
                capabilities: [],
                sessions: [session],
                events: []
            ))
            try store.upsertSkills(indexed)
            try store.setFavourite(true, for: indexed[0].id)
            try store.replaceTags(["  useful ", "work", "useful"], for: indexed[0].id)
            try store.recordSkillUse(SkillUseEvent(
                id: "use-1",
                skillID: indexed[0].id,
                sessionID: session.id,
                harnessID: session.harnessID,
                occurredAt: Date(timeIntervalSince1970: 130)
            ))
            try store.setThreadWorkflowLane("Doing", threadID: "codex-thread-1")

            let records = try store.skillRecords()
            let storedSessions = try store.sessions()
            let threadLanes = try store.threadWorkflowLanes()
            let sourceAfterMetadataChanges = try Data(contentsOf: skillURL)
            expect(storedSessions.first?.totalTokens == 19, "persists normalized session metrics")
            expect(records.count == 1, "persists indexed skill metadata")
            expect(records[0].metadata.isFavourite, "persists a local favourite")
            expect(records[0].metadata.tags == ["useful", "work"], "normalizes local-only tags")
            expect(records[0].useCount == 1, "persists local skill-use events")
            expect(threadLanes["codex-thread-1"] == "Doing", "persists an Operator-only workflow lane by opaque thread ID")
            expect(
                String(decoding: sourceAfterMetadataChanges, as: UTF8.self) == original,
                "does not mutate SKILL.md while changing Operator metadata"
            )
        } catch {
            fatalError("Test failed: could not exercise Operator local metadata store: \(error)")
        }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError("Test failed: \(message)")
        }
    }
}
