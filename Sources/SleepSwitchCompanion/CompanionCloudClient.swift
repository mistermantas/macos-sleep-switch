import CloudKit
import Foundation

struct CompanionCloudClient {
    private let store: CompanionCloudStore

    init(container: CKContainer = CKContainer(identifier: containerIdentifier)) {
        self.store = CompanionCloudStore(container: container)
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await store.accountStatus()
    }

    func ensureStatusSubscription() async throws {
        try await store.ensureStatusSubscription()
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

    func send(_ transfer: CompanionContextTransfer, assetURL: URL) async throws {
        try await store.send(transfer, assetURL: assetURL)
    }

    func fetchResult(for commandID: UUID) async throws -> CompanionRemoteResult? {
        try await store.fetchResult(for: commandID)
    }

    func fetchResult(for transferID: UUID) async throws -> CompanionContextTransferResult? {
        try await store.fetchResult(for: transferID)
    }

    func consumeLastIssue() -> String? {
        store.consumeLastIssue()
    }
}

private let containerIdentifier = CompanionCloudStore.containerIdentifier
