import CloudKit
import Foundation
import OSLog

struct CompanionPendingCommand {
    let recordName: String
    let command: CompanionRemoteCommand?
    let decodeError: String?
    fileprivate let record: CKRecord?

    init(
        recordName: String,
        command: CompanionRemoteCommand?,
        decodeError: String? = nil,
        record: CKRecord? = nil
    ) {
        self.recordName = recordName
        self.command = command
        self.decodeError = decodeError
        self.record = record
    }
}

protocol CompanionCloudStoring: AnyObject {
    var lastIssue: String? { get }

    func accountStatus() async throws -> CKAccountStatus
    func fetchMacs() async throws -> [CompanionMacStatus]
    func publish(status: CompanionMacStatus) async throws
    func publish(history: CompanionHistorySnapshot) async throws
    func fetchHistory(for deviceID: String) async throws -> CompanionHistorySnapshot?
    func send(_ command: CompanionRemoteCommand) async throws
    func fetchResult(for commandID: UUID) async throws -> CompanionRemoteResult?
    func fetchPendingCommands(for deviceID: String) async throws -> [CompanionPendingCommand]
    func finish(
        command: CompanionPendingCommand,
        result: CompanionRemoteResult
    ) async throws
    func reject(
        command: CompanionPendingCommand,
        reason: String
    ) async throws
    func pruneCommands(for deviceID: String, before date: Date) async throws -> Int
    func consumeLastIssue() -> String?
}

enum CompanionCloudStoreError: Error, LocalizedError {
    case commandRecordUnavailable(String)
    case commandCleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandRecordUnavailable:
            return "The remote command record is no longer available."
        case .commandCleanupFailed(let detail):
            return "Sleep Switch could not clean up old remote commands. " + detail
        }
    }
}

final class CompanionCloudStore: CompanionCloudStoring {
    static let containerIdentifier = "iCloud.lt.mantas.sleepswitch"
    static let statusRecordType = "MacStatus"
    static let historyRecordType = "InsightsHistory"
    static let commandRecordType = "RemoteCommand"
    static let statusRecordPrefix = "mac-status-"
    static let historyRecordPrefix = "mac-history-"
    static let commandStatePending = "pending"
    static let commandStateExecuted = "executed"
    static let commandStateRejected = "rejected"

    private static let pageLimit = 100
    private static let maxQueryPages = 20
    private static let logger = Logger(
        subsystem: "lt.mantas.sleepswitch",
        category: "cloudkit"
    )

    let container: CKContainer
    private let issueLock = NSLock()
    private var issueValue: String?

    var lastIssue: String? {
        issueLock.lock()
        defer { issueLock.unlock() }
        return issueValue
    }

    init(container: CKContainer = CKContainer(identifier: containerIdentifier)) {
        self.container = container
    }

    var database: CKDatabase { container.privateCloudDatabase }

    func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    func fetchMacs() async throws -> [CompanionMacStatus] {
        let records = try await fetchRecords(
            type: Self.statusRecordType,
            predicate: NSPredicate(value: true)
        )

        return records.compactMap { record in
            guard let data = record["payload"] as? Data else {
                noteIssue("A MacStatus record is missing its payload.")
                return nil
            }
            do {
                return try CompanionJSON.decoder.decode(CompanionMacStatus.self, from: data)
            } catch {
                noteIssue("A MacStatus payload could not be decoded.")
                return nil
            }
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func publish(status: CompanionMacStatus) async throws {
        let recordID = CKRecord.ID(
            recordName: Self.statusRecordPrefix + status.deviceID
        )
        let record = try await recordForUpsert(
            recordType: Self.statusRecordType,
            recordID: recordID
        )
        record["payload"] = try CompanionJSON.encoder.encode(status) as CKRecordValue
        record["deviceID"] = status.deviceID as CKRecordValue
        record["lastSeen"] = status.lastSeen as CKRecordValue
        record["expiresAt"] = status.lastSeen.addingTimeInterval(15 * 60) as CKRecordValue
        try await database.save(record)
    }

    func publish(history: CompanionHistorySnapshot) async throws {
        let recordID = CKRecord.ID(
            recordName: Self.historyRecordPrefix + history.deviceID
        )
        let record = try await recordForUpsert(
            recordType: Self.historyRecordType,
            recordID: recordID
        )
        record["deviceID"] = history.deviceID as CKRecordValue
        record["payload"] = try CompanionJSON.encoder.encode(history) as CKRecordValue
        record["updatedAt"] = history.updatedAt as CKRecordValue
        record["expiresAt"] = history.updatedAt.addingTimeInterval(15 * 60) as CKRecordValue
        try await database.save(record)
    }

    /// Fixed record names make status/history inexpensive to read, but updating a
    /// freshly-created CKRecord with an existing ID is rejected as a conflict.
    /// Preserve CloudKit's change tag by fetching the current record first.
    private func recordForUpsert(
        recordType: String,
        recordID: CKRecord.ID
    ) async throws -> CKRecord {
        do {
            return try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            return CKRecord(recordType: recordType, recordID: recordID)
        }
    }

    func fetchHistory(for deviceID: String) async throws -> CompanionHistorySnapshot? {
        let records = try await fetchRecords(
            type: Self.historyRecordType,
            predicate: NSPredicate(format: "deviceID == %@", deviceID)
        )
        let record = records.max {
            ($0["updatedAt"] as? Date ?? .distantPast)
                < ($1["updatedAt"] as? Date ?? .distantPast)
        }
        guard let record else { return nil }
        guard let data = record["payload"] as? Data else {
            noteIssue("An InsightsHistory record is missing its payload.")
            return nil
        }
        do {
            return try CompanionJSON.decoder.decode(CompanionHistorySnapshot.self, from: data)
        } catch {
            noteIssue("An InsightsHistory payload could not be decoded.")
            return nil
        }
    }

    func send(_ command: CompanionRemoteCommand) async throws {
        let record = CKRecord(
            recordType: Self.commandRecordType,
            recordID: CKRecord.ID(recordName: command.id.uuidString)
        )
        record["targetDeviceID"] = command.targetDeviceID as CKRecordValue
        record["action"] = command.action.rawValue as CKRecordValue
        record["state"] = Self.commandStatePending as CKRecordValue
        record["createdAt"] = command.createdAt as CKRecordValue
        record["expiresAt"] = command.expiresAt as CKRecordValue
        record["payload"] = try CompanionJSON.encoder.encode(command) as CKRecordValue
        try await database.save(record)
    }

    func fetchResult(for commandID: UUID) async throws -> CompanionRemoteResult? {
        let recordID = CKRecord.ID(recordName: commandID.uuidString)
        let records = try await database.records(for: [recordID])
        guard let result = records[recordID] else { return nil }
        let record: CKRecord
        switch result {
        case .success(let value):
            record = value
        case .failure:
            noteIssue("CloudKit could not read the remote command result.")
            return nil
        }

        guard let state = record["state"] as? String,
              state != Self.commandStatePending,
              let completedAt = record["processedAt"] as? Date
        else {
            return nil
        }

        let accepted = (record["accepted"] as? NSNumber)?.boolValue
            ?? (record["accepted"] as? Bool)
            ?? false
        let executed = state == Self.commandStateExecuted
        let message = (record["resultMessage"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }
        return CompanionRemoteResult(
            commandID: commandID,
            accepted: accepted,
            executed: executed,
            completedAt: completedAt,
            message: message
        )
    }

    func fetchPendingCommands(for deviceID: String) async throws -> [CompanionPendingCommand] {
        try await fetchRecords(
            type: Self.commandRecordType,
            predicate: NSPredicate(
                format: "targetDeviceID == %@ AND state == %@",
                deviceID,
                Self.commandStatePending
            )
        )
        .map { record in
            guard let data = record["payload"] as? Data else {
                let message = "Remote command is missing its payload."
                noteIssue(message)
                return CompanionPendingCommand(
                    recordName: record.recordID.recordName,
                    command: nil,
                    decodeError: message,
                    record: record
                )
            }

            do {
                let command = try CompanionJSON.decoder.decode(
                    CompanionRemoteCommand.self,
                    from: data
                )
                return CompanionPendingCommand(
                    recordName: record.recordID.recordName,
                    command: command,
                    record: record
                )
            } catch {
                let message = "Remote command payload could not be decoded."
                noteIssue(message)
                return CompanionPendingCommand(
                    recordName: record.recordID.recordName,
                    command: nil,
                    decodeError: message,
                    record: record
                )
            }
        }
        .sorted {
            let left = ($0.record?["createdAt"] as? Date) ?? .distantPast
            let right = ($1.record?["createdAt"] as? Date) ?? .distantPast
            return left < right
        }
    }

    func finish(
        command: CompanionPendingCommand,
        result: CompanionRemoteResult
    ) async throws {
        let record = try record(for: command)
        record["state"] = (result.executed
            ? Self.commandStateExecuted
            : Self.commandStateRejected) as CKRecordValue
        record["processedAt"] = result.completedAt as CKRecordValue
        record["accepted"] = result.accepted as CKRecordValue
        record["resultMessage"] = (result.message ?? "") as CKRecordValue
        try await database.save(record)
    }

    func reject(
        command: CompanionPendingCommand,
        reason: String
    ) async throws {
        let result = CompanionRemoteResult(
            commandID: command.command?.id
                ?? UUID(uuidString: command.recordName)
                ?? UUID(),
            accepted: false,
            executed: false,
            completedAt: Date(),
            message: reason
        )
        try await finish(command: command, result: result)
    }

    func pruneCommands(for deviceID: String, before date: Date) async throws -> Int {
        let records = try await fetchRecords(
            type: Self.commandRecordType,
            predicate: NSPredicate(
                format: "targetDeviceID == %@ AND state != %@ AND processedAt < %@",
                deviceID,
                Self.commandStatePending,
                date as NSDate
            )
        )
        let ids = records.map { $0.recordID }
        guard !ids.isEmpty else { return 0 }
        var failures: [Error] = []
        for start in stride(from: 0, to: ids.count, by: 200) {
            let end = min(start + 200, ids.count)
            let result = try await database.modifyRecords(
                saving: [],
                deleting: Array(ids[start..<end]),
                atomically: false
            )
            failures.append(contentsOf: result.deleteResults.values.compactMap { result -> Error? in
                if case .failure(let error) = result { return error }
                return nil
            })
        }
        guard failures.isEmpty else {
            throw CompanionCloudStoreError.commandCleanupFailed(
                "\(failures.count) records could not be deleted."
            )
        }
        return ids.count
    }

    func consumeLastIssue() -> String? {
        issueLock.lock()
        defer { issueLock.unlock() }
        defer { issueValue = nil }
        return issueValue
    }

    private func record(for command: CompanionPendingCommand) throws -> CKRecord {
        guard let record = command.record else {
            throw CompanionCloudStoreError.commandRecordUnavailable(command.recordName)
        }
        return record
    }

    private func fetchRecords(
        type: String,
        predicate: NSPredicate
    ) async throws -> [CKRecord] {
        let query = CKQuery(recordType: type, predicate: predicate)
        var records: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?
        var page = 0

        repeat {
            let result: (
                matchResults: [(CKRecord.ID, Result<CKRecord, Error>)],
                queryCursor: CKQueryOperation.Cursor?
            )
            if let cursor {
                result = try await database.records(
                    continuingMatchFrom: cursor,
                    resultsLimit: Self.pageLimit
                )
            } else {
                result = try await database.records(
                    matching: query,
                    inZoneWith: nil,
                    resultsLimit: Self.pageLimit
                )
            }

            for (recordID, matchResult) in result.matchResults {
                switch matchResult {
                case .success(let record):
                    records.append(record)
                case .failure:
                    noteIssue(
                        "CloudKit returned an unreadable record on page \(page + 1)."
                    )
                    _ = recordID
                }
            }

            page += 1
            cursor = result.queryCursor
            if page >= Self.maxQueryPages, cursor != nil {
                noteIssue("CloudKit (type) query reached its safety page limit.")
                cursor = nil
            }
        } while cursor != nil

        return records
    }

    private func noteIssue(_ message: String) {
        issueLock.lock()
        issueValue = message
        issueLock.unlock()
        Self.logger.error("\(message, privacy: .public)")
    }
}

enum CompanionJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

enum CompanionDeviceIdentity {
    static func load(
        key: String,
        defaults: UserDefaults = .standard
    ) -> String {
        if let stored = defaults.string(forKey: key), !stored.isEmpty {
            return stored
        }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: key)
        return value
    }
}
