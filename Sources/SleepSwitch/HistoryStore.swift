import Foundation
import SQLite3

enum HistoryStoreError: Error, LocalizedError {
    case couldNotOpen(URL, String)
    case statementFailed(String, String)
    case databaseUnavailable

    var errorDescription: String? {
        switch self {
        case .couldNotOpen(let url, let message):
            return "Sleep Switch could not open history at \(url.path). \(message)"
        case .statementFailed(_, let message):
            return "Sleep Switch history could not be updated. \(message)"
        case .databaseUnavailable:
            return "Sleep Switch history is unavailable. Live readings remain available."
        }
    }
}

final class HistoryStore {
    static let defaultDatabaseName = "History.sqlite"
    static let defaultRawRetention: TimeInterval = 30 * 24 * 60 * 60
    static let defaultRollupRetention: TimeInterval = 13 * 30 * 24 * 60 * 60

    let databaseURL: URL
    private var database: OpaquePointer?
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL = HistoryStore.defaultDatabaseURL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var openedDatabase: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &openedDatabase,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let openedDatabase else {
            let message = openedDatabase.map(Self.errorMessage) ?? "SQLite could not open the database."
            if let openedDatabase { sqlite3_close(openedDatabase) }
            throw HistoryStoreError.couldNotOpen(databaseURL, message)
        }
        database = openedDatabase
        sqlite3_busy_timeout(openedDatabase, 1_000)
        do {
            try createSchema()
        } catch {
            sqlite3_close(openedDatabase)
            database = nil
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    static var defaultDatabaseURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Sleep Switch", isDirectory: true)
            .appendingPathComponent(defaultDatabaseName)
    }

    func saveEnergy(_ bucket: EnergyBucket) throws {
        let sql = """
        INSERT INTO energy_buckets
            (bucket_start, duration_seconds, average_watts, peak_watts,
             kilowatt_hours, source, confidence, sample_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(bucket_start) DO UPDATE SET
            duration_seconds = excluded.duration_seconds,
            average_watts = excluded.average_watts,
            peak_watts = excluded.peak_watts,
            kilowatt_hours = excluded.kilowatt_hours,
            source = excluded.source,
            confidence = excluded.confidence,
            sample_count = excluded.sample_count;
        """
        try run(sql) { statement in
            self.bindDouble(statement, index: 1, value: bucket.bucketStart.timeIntervalSince1970)
            self.bindInt(statement, index: 2, value: bucket.durationSeconds)
            self.bindOptionalDouble(statement, index: 3, value: bucket.averageWatts)
            self.bindOptionalDouble(statement, index: 4, value: bucket.peakWatts)
            self.bindOptionalDouble(statement, index: 5, value: bucket.kilowattHours)
            self.bindText(statement, index: 6, value: bucket.source.rawValue)
            self.bindText(statement, index: 7, value: bucket.confidence.rawValue)
            self.bindInt(statement, index: 8, value: bucket.sampleCount)
        }
    }

    func saveAgentInterval(_ interval: AgentActivityInterval) throws {
        let sql = """
        INSERT INTO agent_intervals
            (id, agent_id, agent_name, started_at, ended_at, state, peak_session_count)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            agent_id = excluded.agent_id,
            agent_name = excluded.agent_name,
            started_at = excluded.started_at,
            ended_at = excluded.ended_at,
            state = excluded.state,
            peak_session_count = excluded.peak_session_count;
        """
        try run(sql) { statement in
            self.bindText(statement, index: 1, value: interval.id.uuidString)
            self.bindText(statement, index: 2, value: interval.agentID)
            self.bindText(statement, index: 3, value: interval.agentName)
            self.bindDouble(statement, index: 4, value: interval.startedAt.timeIntervalSince1970)
            self.bindOptionalDouble(
                statement,
                index: 5,
                value: interval.endedAt?.timeIntervalSince1970
            )
            self.bindText(statement, index: 6, value: interval.state.rawValue)
            self.bindInt(statement, index: 7, value: interval.peakSessionCount)
        }
    }

    func energyBuckets(from start: Date, to end: Date) throws -> [EnergyBucket] {
        let sql = """
        SELECT bucket_start, duration_seconds, average_watts, peak_watts,
               kilowatt_hours, source, confidence, sample_count
        FROM energy_buckets
        WHERE bucket_start >= ? AND bucket_start <= ?
        ORDER BY bucket_start ASC;
        """
        return try query(sql, bind: { statement in
            self.bindDouble(statement, index: 1, value: start.timeIntervalSince1970)
            self.bindDouble(statement, index: 2, value: end.timeIntervalSince1970)
        }) { statement in
            EnergyBucket(
                bucketStart: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                durationSeconds: Int(sqlite3_column_int(statement, 1)),
                averageWatts: optionalDouble(statement, column: 2),
                peakWatts: optionalDouble(statement, column: 3),
                kilowattHours: optionalDouble(statement, column: 4),
                source: EnergySource(
                    rawValue: text(statement, column: 5)
                ) ?? .unavailable,
                confidence: EnergyConfidence(
                    rawValue: text(statement, column: 6)
                ) ?? .unavailable,
                sampleCount: Int(sqlite3_column_int(statement, 7))
            )
        }
    }

    func agentIntervals(from start: Date, to end: Date) throws -> [AgentActivityInterval] {
        let sql = """
        SELECT id, agent_id, agent_name, started_at, ended_at, state, peak_session_count
        FROM agent_intervals
        WHERE started_at <= ? AND (ended_at IS NULL OR ended_at >= ?)
        ORDER BY started_at ASC;
        """
        return try query(sql, bind: { statement in
            self.bindDouble(statement, index: 1, value: end.timeIntervalSince1970)
            self.bindDouble(statement, index: 2, value: start.timeIntervalSince1970)
        }) { statement in
            AgentActivityInterval(
                id: UUID(uuidString: text(statement, column: 0)) ?? UUID(),
                agentID: text(statement, column: 1),
                agentName: text(statement, column: 2),
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                endedAt: optionalDouble(statement, column: 4)
                    .map(Date.init(timeIntervalSince1970:)),
                state: AgentActivityState(
                    rawValue: text(statement, column: 5)
                ) ?? .unknown,
                peakSessionCount: Int(sqlite3_column_int(statement, 6))
            )
        }
    }

    func prune(now: Date = Date()) throws {
        let rawCutoff = now.addingTimeInterval(-Self.defaultRawRetention)
        let rollupCutoff = now.addingTimeInterval(-Self.defaultRollupRetention)
        try run("DELETE FROM energy_buckets WHERE bucket_start < ?;") { statement in
            self.bindDouble(statement, index: 1, value: rawCutoff.timeIntervalSince1970)
        }
        try run("DELETE FROM agent_intervals WHERE started_at < ? AND (ended_at IS NULL OR ended_at < ?);") { statement in
            self.bindDouble(statement, index: 1, value: rollupCutoff.timeIntervalSince1970)
            self.bindDouble(statement, index: 2, value: rollupCutoff.timeIntervalSince1970)
        }
        try run("PRAGMA wal_checkpoint(PASSIVE);")
    }

    func deleteAll() throws {
        try run("BEGIN IMMEDIATE;")
        do {
            try run("DELETE FROM energy_buckets;")
            try run("DELETE FROM agent_intervals;")
            try run("COMMIT;")
        } catch {
            try? run("ROLLBACK;")
            throw error
        }
    }

    var storageBytes: Int64 {
        let paths = [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"), URL(fileURLWithPath: databaseURL.path + "-shm")]
        var total: Int64 = 0
        for url in paths {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber else {
                continue
            }
            total += size.int64Value
        }
        return total
    }

    private func createSchema() throws {
        try run("PRAGMA journal_mode = WAL;")
        try run("PRAGMA synchronous = NORMAL;")
        try run("""
        CREATE TABLE IF NOT EXISTS energy_buckets (
            bucket_start REAL PRIMARY KEY,
            duration_seconds INTEGER NOT NULL,
            average_watts REAL,
            peak_watts REAL,
            kilowatt_hours REAL,
            source TEXT NOT NULL,
            confidence TEXT NOT NULL,
            sample_count INTEGER NOT NULL
        );
        """)
        try run("""
        CREATE TABLE IF NOT EXISTS agent_intervals (
            id TEXT PRIMARY KEY,
            agent_id TEXT NOT NULL,
            agent_name TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL,
            state TEXT NOT NULL,
            peak_session_count INTEGER NOT NULL
        );
        """)
        try run("CREATE INDEX IF NOT EXISTS agent_intervals_started_at ON agent_intervals(started_at);")
    }

    private func run(
        _ sql: String,
        bind: ((OpaquePointer) -> Void)? = nil
    ) throws {
        guard let database else { throw HistoryStoreError.databaseUnavailable }
        var statement: OpaquePointer?
        let prepareResult = sql.withCString {
            sqlite3_prepare_v2(database, $0, -1, &statement, nil)
        }
        guard prepareResult == SQLITE_OK, let statement else {
            throw statementError(sql)
        }
        defer { sqlite3_finalize(statement) }
        bind?(statement)
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else {
            throw statementError(sql)
        }
    }

    private func query<T>(
        _ sql: String,
        bind: ((OpaquePointer) -> Void)? = nil,
        map: (OpaquePointer) -> T
    ) throws -> [T] {
        guard let database else { throw HistoryStoreError.databaseUnavailable }
        var statement: OpaquePointer?
        let prepareResult = sql.withCString {
            sqlite3_prepare_v2(database, $0, -1, &statement, nil)
        }
        guard prepareResult == SQLITE_OK, let statement else {
            throw statementError(sql)
        }
        defer { sqlite3_finalize(statement) }
        bind?(statement)

        var values: [T] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            values.append(map(statement))
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else {
            throw statementError(sql)
        }
        return values
    }

    private func statementError(_ sql: String) -> HistoryStoreError {
        HistoryStoreError.statementFailed(sql, database.map(Self.errorMessage) ?? "Unknown SQLite error.")
    }

    private static func errorMessage(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }

    private func bindDouble(_ statement: OpaquePointer, index: Int32, value: Double) {
        sqlite3_bind_double(statement, index, value)
    }

    private func bindOptionalDouble(_ statement: OpaquePointer, index: Int32, value: Double?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        bindDouble(statement, index: index, value: value)
    }

    private func bindInt(_ statement: OpaquePointer, index: Int32, value: Int) {
        sqlite3_bind_int(statement, index, Int32(value))
    }

    private func bindText(_ statement: OpaquePointer, index: Int32, value: String) {
        _ = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, sqliteTransient)
        }
    }

    private func optionalDouble(_ statement: OpaquePointer, column: Int32) -> Double? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil
            : sqlite3_column_double(statement, column)
    }

    private func text(_ statement: OpaquePointer, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }
}
