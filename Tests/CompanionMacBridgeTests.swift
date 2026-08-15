import CloudKit
import Foundation

@MainActor
enum CompanionMacBridgeTests {
    static func run() async {
        await testPublishesAndCoalesces()
        await testQuarantinesMalformedCommands()
        await testPersistsCommandIdempotency()
        await testSurfacesAccountFailures()
        await testRecoversFromStalledSync()
    }

    private static func testPublishesAndCoalesces() async {
        let defaults = makeDefaults()
        let cloud = FakeCompanionCloudStore()
        let bridge = makeBridge(cloud: cloud, defaults: defaults)

        await bridge.synchronizeAndWait(force: true)
        expect(cloud.statusPublishCount == 1, "publishes an initial Mac status")
        expect(cloud.historyPublishCount == 1, "publishes an initial history snapshot")
        expect(bridge.diagnostics.state == .succeeded, "reports a successful sync")

        await bridge.synchronizeAndWait()
        expect(cloud.statusPublishCount == 1, "coalesces an unchanged status heartbeat")
        expect(cloud.historyPublishCount == 1, "coalesces an unchanged history snapshot")
    }

    private static func testQuarantinesMalformedCommands() async {
        let defaults = makeDefaults()
        let cloud = FakeCompanionCloudStore()
        cloud.pendingCommands = [
            CompanionPendingCommand(
                recordName: "malformed-command",
                command: nil,
                decodeError: "Remote command payload is invalid."
            )
        ]
        let bridge = makeBridge(cloud: cloud, defaults: defaults)

        await bridge.synchronizeAndWait(force: true)
        expect(cloud.rejectedReasons == ["Remote command payload is invalid."], "rejects malformed commands")
        expect(bridge.diagnostics.processedCommandCount == 1, "counts quarantined commands")
    }

    private static func testPersistsCommandIdempotency() async {
        let defaults = makeDefaults()
        let cloud = FakeCompanionCloudStore()
        let command = makeCommand()
        cloud.pendingCommands = [CompanionPendingCommand(recordName: command.id.uuidString, command: command)]
        var handlerCalls = 0
        let firstBridge = makeBridge(cloud: cloud, defaults: defaults) { _ in
            handlerCalls += 1
            return CompanionRemoteResult(
                commandID: command.id,
                accepted: true,
                executed: true,
                completedAt: Date(),
                message: "Executed once."
            )
        }

        await firstBridge.synchronizeAndWait(force: true)
        expect(handlerCalls == 1, "executes a new command once")
        expect(cloud.statusPublishCount == 2, "republishes fresh status after a remote action")

        let secondBridge = makeBridge(cloud: cloud, defaults: defaults) { _ in
            handlerCalls += 1
            return CompanionRemoteResult(
                commandID: command.id,
                accepted: true,
                executed: true,
                completedAt: Date(),
                message: "Should not execute."
            )
        }
        await secondBridge.synchronizeAndWait(force: true)
        expect(handlerCalls == 1, "does not replay a command after a bridge restart")
        expect(cloud.finishedResults.count == 2, "finishes both the original and replayed record")
    }

    private static func testSurfacesAccountFailures() async {
        let defaults = makeDefaults()
        let cloud = FakeCompanionCloudStore()
        cloud.accountError = FakeCloudError.accountUnavailable
        let bridge = makeBridge(cloud: cloud, defaults: defaults)

        await bridge.synchronizeAndWait(force: true)
        expect(bridge.diagnostics.state == .failed, "reports an account-status failure")
        expect(bridge.diagnostics.lastError != nil, "retains a safe account-status diagnostic")
    }

    private static func testRecoversFromStalledSync() async {
        let defaults = makeDefaults()
        let cloud = FakeCompanionCloudStore()
        cloud.accountDelayNanoseconds = 60 * 1_000_000_000
        let bridge = makeBridge(
            cloud: cloud,
            defaults: defaults,
            stalledSyncInterval: 1
        )
        let startedAt = Date(timeIntervalSince1970: 100)

        bridge.synchronize(force: true, now: startedAt)
        while cloud.accountStatusCallCount == 0 {
            await Task.yield()
        }

        cloud.accountDelayNanoseconds = 0
        bridge.synchronize(
            force: true,
            now: startedAt.addingTimeInterval(2)
        )
        await bridge.synchronizeAndWait(
            now: startedAt.addingTimeInterval(2)
        )

        expect(cloud.statusPublishCount == 1, "publishes after replacing a stalled sync")
        expect(
            bridge.diagnostics.stalledSyncRecoveryCount == 1,
            "records the stalled-sync recovery"
        )
        expect(bridge.diagnostics.state == .succeeded, "returns to a healthy sync state")
    }

    private static func makeBridge(
        cloud: FakeCompanionCloudStore,
        defaults: UserDefaults,
        stalledSyncInterval: TimeInterval = 2 * 60,
        commandHandler: @escaping (CompanionRemoteCommand) -> CompanionRemoteResult = { command in
            CompanionRemoteResult(
                commandID: command.id,
                accepted: true,
                executed: true,
                completedAt: Date(),
                message: "Executed."
            )
        }
    ) -> CompanionMacBridge {
        CompanionMacBridge(
            cloud: cloud,
            deviceID: "test-mac",
            statusProvider: { makeStatus() },
            historyProvider: { makeHistory() },
            commandHandler: commandHandler,
            defaults: defaults,
            statusHeartbeatInterval: 60 * 60,
            stalledSyncInterval: stalledSyncInterval
        )
    }

    private static func makeStatus() -> CompanionMacStatus {
        CompanionMacStatus(
            deviceID: "test-mac",
            displayName: "Test Mac",
            build: "test",
            lastSeen: Date(timeIntervalSince1970: 0),
            uptimeSeconds: 100,
            powerSource: .ac,
            batteryPercent: 100,
            thermalState: "nominal",
            activeAgentCount: 1,
            activeSessionCount: 1,
            awakeMode: "preventSleep",
            displayAsleep: false,
            isKeepingAwake: true,
            keepDisplayAwake: false,
            automaticAgentAwakeEnabled: true,
            wakeDisplayWhenAgentsFinish: false,
            estimatedWatts: 25,
            energySource: .ac,
            energyConfidence: .estimated,
            isCharging: true,
            capabilities: CompanionMacCapabilities(supportsCloudKit: true)
        )
    }

    private static func makeHistory() -> CompanionHistorySnapshot {
        .empty(deviceID: "test-mac", updatedAt: Date(timeIntervalSince1970: 0))
    }

    private static func makeCommand() -> CompanionRemoteCommand {
        let now = Date()
        return CompanionRemoteCommand(
            id: UUID(),
            targetDeviceID: "test-mac",
            action: .sleepDisplay,
            parameters: [:],
            requesterDeviceID: "test-phone",
            nonce: UUID().uuidString,
            createdAt: now,
            expiresAt: now.addingTimeInterval(60),
            policyVersion: 1
        )
    }

    private static func makeDefaults() -> UserDefaults {
        let suite = "CompanionMacBridgeTests." + UUID().uuidString
        return UserDefaults(suiteName: suite)!
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("Test failed: \(message)") }
    }
}

private final class FakeCompanionCloudStore: CompanionCloudStoring {
    var accountStatusValue: CKAccountStatus = .available
    var accountError: Error?
    var lastIssue: String?
    var pendingCommands: [CompanionPendingCommand] = []
    var statusPublishCount = 0
    var historyPublishCount = 0
    var rejectedReasons: [String] = []
    var finishedResults: [CompanionRemoteResult] = []
    var accountDelayNanoseconds: UInt64 = 0
    var accountStatusCallCount = 0

    func accountStatus() async throws -> CKAccountStatus {
        accountStatusCallCount += 1
        if accountDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: accountDelayNanoseconds)
        }
        if let accountError { throw accountError }
        return accountStatusValue
    }

    func fetchMacs() async throws -> [CompanionMacStatus] { [] }
    func publish(status: CompanionMacStatus) async throws { statusPublishCount += 1 }
    func publish(history: CompanionHistorySnapshot) async throws { historyPublishCount += 1 }
    func fetchHistory(for deviceID: String) async throws -> CompanionHistorySnapshot? { nil }
    func send(_ command: CompanionRemoteCommand) async throws {}
    func fetchResult(for commandID: UUID) async throws -> CompanionRemoteResult? { nil }
    func fetchPendingCommands(for deviceID: String) async throws -> [CompanionPendingCommand] { pendingCommands }

    func finish(
        command: CompanionPendingCommand,
        result: CompanionRemoteResult
    ) async throws {
        finishedResults.append(result)
    }

    func reject(
        command: CompanionPendingCommand,
        reason: String
    ) async throws {
        rejectedReasons.append(reason)
    }

    func pruneCommands(for deviceID: String, before date: Date) async throws -> Int { 0 }

    func consumeLastIssue() -> String? {
        defer { lastIssue = nil }
        return lastIssue
    }
}

private enum FakeCloudError: Error {
    case accountUnavailable
}
