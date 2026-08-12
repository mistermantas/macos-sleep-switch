import CloudKit
import Foundation

struct CompanionCloudClient {
    private let store: CompanionCloudStore

    init(container: CKContainer = CKContainer(identifier: containerIdentifier)) {
        self.store = CompanionCloudStore(container: container)
    }

    func accountStatus() async -> CKAccountStatus {
        await store.accountStatus()
    }

    func fetchMacs() async throws -> [CompanionMacStatus] {
        try await store.fetchMacs()
    }

    func fetchHistory(for deviceID: String) async throws -> CompanionHistorySnapshot? {
        try await store.fetchHistory(for: deviceID)
    }

    func send(_ command: CompanionRemoteCommand) async throws {
        try await store.send(command)
    }
}

private let containerIdentifier = CompanionCloudStore.containerIdentifier
