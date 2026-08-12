import CloudKit
import Foundation

/// Polls the user's private CloudKit database while the Mac is awake. The
/// bridge is intentionally pull-based: a sleeping Mac cannot receive a push
/// command, and a stale status is safer than pretending that a command ran.
@MainActor
final class CompanionMacBridge {
    typealias StatusProvider = () -> CompanionMacStatus
    typealias HistoryProvider = () -> CompanionHistorySnapshot
    typealias CommandHandler = (CompanionRemoteCommand) -> CompanionRemoteResult

    private let cloud: CompanionCloudStore
    private let statusProvider: StatusProvider
    private let historyProvider: HistoryProvider
    private let commandHandler: CommandHandler
    private var timer: Timer?
    private var syncTask: Task<Void, Never>?
    private var seenNonces = Set<String>()
    private var cachedResults: [String: CompanionRemoteResult] = [:]
    private let deviceIDValue: String

    var deviceID: String { deviceIDValue }

    init(
        cloud: CompanionCloudStore = CompanionCloudStore(),
        deviceID: String = CompanionDeviceIdentity.load(key: "companionMacDeviceID"),
        statusProvider: @escaping StatusProvider,
        historyProvider: @escaping HistoryProvider,
        commandHandler: @escaping CommandHandler
    ) {
        self.cloud = cloud
        self.deviceIDValue = deviceID
        self.statusProvider = statusProvider
        self.historyProvider = historyProvider
        self.commandHandler = commandHandler
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(
            withTimeInterval: 15,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.synchronize()
            }
        }
        timer?.tolerance = 3
        synchronize()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        syncTask?.cancel()
        syncTask = nil
    }

    func synchronize() {
        guard syncTask == nil else { return }
        let status = statusProvider().refreshingLastSeen()
        let history = historyProvider()
        syncTask = Task { [weak self] in
            guard let self else { return }
            defer { self.syncTask = nil }
            guard await self.cloud.accountStatus() == .available else { return }

            do {
                try await self.cloud.publish(status: status)
                try await self.cloud.publish(history: history)
                try await self.processPendingCommands()
            } catch {
                // The menu bar app remains fully functional when iCloud is
                // unavailable. The next cycle will retry without surfacing a
                // noisy alert for a background transport failure.
            }
        }
    }

    private func processPendingCommands() async throws {
        let records = try await cloud.fetchPendingCommands(for: deviceIDValue)
        for record in records {
            guard let command = cloud.decodeCommand(from: record) else { continue }

            let result: CompanionRemoteResult
            if let cachedResult = cachedResults[command.nonce] {
                // A result write can fail after the local action has already
                // run. Reuse the result rather than executing a destructive
                // command twice on the next polling cycle.
                result = cachedResult
            } else if seenNonces.contains(command.nonce) {
                continue
            } else {
                result = commandHandler(command)
                seenNonces.insert(command.nonce)
                cachedResults[command.nonce] = result
            }

            do {
                try await cloud.finish(commandRecord: record, result: result)
                cachedResults.removeValue(forKey: command.nonce)
            } catch {
                // Leave the record pending if CloudKit rejected the write. A
                // later cycle can retry the cached result without executing
                // the action twice.
            }
        }
    }
}
