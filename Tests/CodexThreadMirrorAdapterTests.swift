import Foundation
import SQLite3

enum CodexThreadMirrorAdapterTests {
    static func run() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "sleep-switch-codex-mirror-\(UUID().uuidString)",
            isDirectory: true
        )
        let stateURL = root.appendingPathComponent("state.sqlite")
        let historyURL = root.appendingPathComponent("history.sqlite")
        defer { try? fileManager.removeItem(at: root) }

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try populateStateDatabase(at: stateURL)
            try populateHistoryDatabase(at: historyURL)
        } catch {
            fatalError("Test failed: could not prepare Codex mirror fixture: \(error)")
        }

        let snapshot = CodexThreadMirrorAdapter(
            stateDatabaseURL: stateURL,
            historyDatabaseURL: historyURL
        ).snapshot()
        expect(snapshot.isAvailable, "opens the local Codex catalog read-only")
        expect(snapshot.threads.count == 3, "mirrors visible Codex chats")

        let running = snapshot.threads.first { $0.id == "running" }
        expect(running?.title == "Make the board useful", "uses Codex chat titles")
        expect(running?.sectionName == "RND", "uses Codex sidebar sections")
        expect(running?.projectName == "Sleep Switch", "uses Codex project names")
        expect(running?.isPinned == true, "uses Codex pin state")
        expect(running?.status == .running, "maps active turn progress to running")
        expect(running?.messages.map(\.text) == ["Show actual tasks", "I am reading the local catalog."], "keeps recent local messages in display memory")

        expect(snapshot.threads.first { $0.id == "finished" }?.status == .finished, "maps completed turns")
        expect(snapshot.threads.first { $0.id == "stopped" }?.status == .stopped, "maps cancelled turns")
        testMovingThreadUpdatesOnlyCodexSidebarAssignment()
    }

    private static func testMovingThreadUpdatesOnlyCodexSidebarAssignment() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "sleep-switch-codex-section-move-\(UUID().uuidString)",
            isDirectory: true
        )
        let databaseURL = root.appendingPathComponent("state.sqlite")
        defer { try? fileManager.removeItem(at: root) }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            var database: OpaquePointer?
            guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
                fatalError("Test failed: could not create Codex sidebar fixture")
            }
            defer { sqlite3_close(database) }
            let schema = """
            CREATE TABLE threads (id TEXT PRIMARY KEY, thread_section_id TEXT, section_position INTEGER, title TEXT);
            INSERT INTO threads VALUES ('move-me', 'old', 2, 'unchanged title');
            INSERT INTO threads VALUES ('already-there', 'new', 5, 'another title');
            """
            guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
                fatalError("Test failed: could not populate Codex sidebar fixture")
            }
            try CodexThreadSectionController(stateDatabaseURL: databaseURL)
                .move(threadID: "move-me", toSectionID: "new")
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, "SELECT thread_section_id, section_position, title FROM threads WHERE id = 'move-me';", -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                fatalError("Test failed: could not read moved Codex fixture")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                fatalError("Test failed: moved Codex fixture row is missing")
            }
            let section = String(cString: sqlite3_column_text(statement, 0))
            let position = sqlite3_column_int(statement, 1)
            let title = String(cString: sqlite3_column_text(statement, 2))
            expect(section == "new", "moves a Codex chat to its target sidebar section")
            expect(position == 6, "places a moved chat after existing cards in the target section")
            expect(title == "unchanged title", "does not mutate Codex chat content while moving sections")
        } catch {
            fatalError("Test failed: could not exercise Codex sidebar movement: \(error)")
        }
    }

    private static func populateStateDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "CodexMirrorTest", code: 1)
        }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE thread_sections (id TEXT PRIMARY KEY, name TEXT, appearance TEXT);
        CREATE TABLE projects (id TEXT PRIMARY KEY, name TEXT);
        CREATE TABLE threads (
          id TEXT PRIMARY KEY, title TEXT, name TEXT, preview TEXT, first_user_message TEXT, cwd TEXT,
          archived INTEGER, is_pinned INTEGER, thread_section_id TEXT, section_position INTEGER,
          project_id TEXT, recency_at_ms INTEGER
        );
        INSERT INTO thread_sections VALUES ('rnd', 'RND', NULL);
        INSERT INTO projects VALUES ('sleep-switch', 'Sleep Switch');
        INSERT INTO threads VALUES
          ('running', 'Generated title', 'Make the board useful', 'Show actual tasks', 'Show actual tasks', '/work/sleep-switch', 0, 1, 'rnd', 2, 'sleep-switch', 1788500000000),
          ('finished', 'Ship the companion', NULL, 'Build passed', 'Ship the companion', '/work/sleep-switch', 0, 0, NULL, NULL, 'sleep-switch', 1788400000000),
          ('stopped', 'Try a fan curve', '', 'Stopped safely', 'Try a fan curve', '/work/lab', 1, 0, NULL, NULL, NULL, 1788300000000);
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "CodexMirrorTest", code: 2)
        }
    }

    private static func populateHistoryDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "CodexMirrorTest", code: 3)
        }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE thread_turns (
          thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER, status TEXT,
          started_at INTEGER, completed_at INTEGER
        );
        CREATE TABLE thread_items (
          thread_id TEXT, turn_id TEXT, item_id TEXT, rollout_ordinal INTEGER,
          created_at_ms INTEGER, item_json TEXT, item_type TEXT
        );
        INSERT INTO thread_turns VALUES
          ('running', 'r1', 1, 'in_progress', 1788500000000, NULL),
          ('finished', 'f1', 1, 'completed', 1788400000000, 1788400100000),
          ('stopped', 's1', 1, 'interrupted', 1788300000000, NULL);
        INSERT INTO thread_items VALUES
          ('running', 'r1', 'm1', 1, 1788500000000, '{"type":"userMessage","text":"Show actual tasks"}', 'userMessage'),
          ('running', 'r1', 'm2', 2, 1788500001000, '{"type":"agentMessage","text":"I am reading the local catalog."}', 'agentMessage');
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "CodexMirrorTest", code: 4)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("Test failed: \(message)") }
    }
}
