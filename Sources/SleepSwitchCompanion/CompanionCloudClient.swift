import CloudKit
import Foundation

struct CompanionCloudClient {
    static let containerIdentifier = "iCloud.lt.mantas.sleepswitch"

    let container: CKContainer

    init(container: CKContainer = CKContainer(identifier: containerIdentifier)) {
        self.container = container
    }

    func accountStatus() async -> CKAccountStatus {
        (try? await container.accountStatus()) ?? .couldNotDetermine
    }

    func fetchMacs() async throws -> [CompanionMacStatus] {
        let query = CKQuery(
            recordType: "MacStatus",
            predicate: NSPredicate(value: true)
        )
        let result = try await container.privateCloudDatabase.records(
            matching: query,
            inZoneWith: nil
        )
        return result.matchResults.compactMap { _, result in
            guard case .success(let record) = result,
                  let data = record["payload"] as? Data else {
                return nil
            }
            return try? JSONDecoder().decode(CompanionMacStatus.self, from: data)
        }
    }

    func send(_ command: CompanionRemoteCommand) async throws {
        let record = CKRecord(
            recordType: "RemoteCommand",
            recordID: CKRecord.ID(recordName: command.id.uuidString)
        )
        record["targetDeviceID"] = command.targetDeviceID as CKRecordValue
        record["action"] = command.action.rawValue as CKRecordValue
        record["payload"] = try JSONEncoder().encode(command) as CKRecordValue
        try await container.privateCloudDatabase.save(record)
    }
}
