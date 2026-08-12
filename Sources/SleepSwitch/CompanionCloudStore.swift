import CloudKit
import Foundation

/// The companion uses the user's private CloudKit database. Nothing is shared
/// publicly and no developer-operated server is involved. A Mac publishes one
/// short-lived status record and consumes commands addressed to its device ID.
struct CompanionCloudStore {
    static let containerIdentifier = "iCloud.lt.mantas.sleepswitch"
    static let statusRecordType = "MacStatus"
    static let historyRecordType = "InsightsHistory"
    static let commandRecordType = "RemoteCommand"
    static let statusRecordPrefix = "mac-status-"
    static let historyRecordPrefix = "mac-history-"
    static let commandStatePending = "pending"

    let container: CKContainer

    init(container: CKContainer = CKContainer(identifier: containerIdentifier)) {
        self.container = container
    }

    var database: CKDatabase { container.privateCloudDatabase }

    func accountStatus() async -> CKAccountStatus {
        (try? await container.accountStatus()) ?? .couldNotDetermine
    }

    func fetchMacs() async throws -> [CompanionMacStatus] {
        let records = try await fetchRecords(
            type: Self.statusRecordType,
            predicate: NSPredicate(value: true)
        )

        return records.compactMap { record in
            guard let data = record["payload"] as? Data else { return nil }
            return try? CompanionJSON.decoder.decode(CompanionMacStatus.self, from: data)
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func publish(status: CompanionMacStatus) async throws {
        let record = CKRecord(
            recordType: Self.statusRecordType,
            recordID: CKRecord.ID(
                recordName: Self.statusRecordPrefix + status.deviceID
            )
        )
        record["payload"] = try CompanionJSON.encoder.encode(status) as CKRecordValue
        record["deviceID"] = status.deviceID as CKRecordValue
        record["lastSeen"] = status.lastSeen as CKRecordValue
        record["expiresAt"] = status.lastSeen.addingTimeInterval(15 * 60) as CKRecordValue
        try await database.save(record)
    }

    func publish(history: CompanionHistorySnapshot) async throws {
        let record = CKRecord(
            recordType: Self.historyRecordType,
            recordID: CKRecord.ID(
                recordName: Self.historyRecordPrefix + history.deviceID
            )
        )
        record["deviceID"] = history.deviceID as CKRecordValue
        record["payload"] = try CompanionJSON.encoder.encode(history) as CKRecordValue
        record["updatedAt"] = history.updatedAt as CKRecordValue
        record["expiresAt"] = history.updatedAt.addingTimeInterval(15 * 60) as CKRecordValue
        try await database.save(record)
    }

    func fetchHistory(for deviceID: String) async throws -> CompanionHistorySnapshot? {
        let records = try await fetchRecords(
            type: Self.historyRecordType,
            predicate: NSPredicate(format: "deviceID == %@", deviceID)
        )
        guard let data = records.first?["payload"] as? Data else { return nil }
        return try CompanionJSON.decoder.decode(CompanionHistorySnapshot.self, from: data)
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

    func fetchPendingCommands(for deviceID: String) async throws -> [CKRecord] {
        try await fetchRecords(
            type: Self.commandRecordType,
            predicate: NSPredicate(
                format: "targetDeviceID == %@ AND state == %@",
                deviceID,
                Self.commandStatePending
            )
        )
        .sorted {
            let left = ($0["createdAt"] as? Date) ?? .distantPast
            let right = ($1["createdAt"] as? Date) ?? .distantPast
            return left < right
        }
    }

    func decodeCommand(from record: CKRecord) -> CompanionRemoteCommand? {
        guard let data = record["payload"] as? Data else { return nil }
        return try? CompanionJSON.decoder.decode(CompanionRemoteCommand.self, from: data)
    }

    func finish(commandRecord: CKRecord, result: CompanionRemoteResult) async throws {
        commandRecord["state"] = (result.executed ? "executed" : "rejected") as CKRecordValue
        commandRecord["processedAt"] = result.completedAt as CKRecordValue
        commandRecord["accepted"] = result.accepted as CKRecordValue
        commandRecord["resultMessage"] = (result.message ?? "") as CKRecordValue
        try await database.save(commandRecord)
    }

    private func fetchRecords(
        type: String,
        predicate: NSPredicate
    ) async throws -> [CKRecord] {
        let query = CKQuery(recordType: type, predicate: predicate)
        let result = try await database.records(matching: query, inZoneWith: nil)
        return result.matchResults.compactMap { _, result in
            guard case .success(let record) = result else { return nil }
            return record
        }
    }
}

enum CompanionJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
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
