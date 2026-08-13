import CloudKit
import Foundation
import OSLog

enum CompanionSyncState: String, Equatable {
    case idle
    case syncing
    case unavailable
    case succeeded
    case failed
}

struct CompanionSyncDiagnostics: Equatable {
    var state: CompanionSyncState = .idle
    var lastSuccessAt: Date?
    var lastFailureAt: Date?
    var lastError: String?
    var lastWarning: String?
    var consecutiveFailures = 0
    var publishedStatusCount = 0
    var publishedHistoryCount = 0
    var processedCommandCount = 0
    var lastCommandAt: Date?
}

/// Polls the user's private CloudKit database while the Mac is awake. The
/// bridge is intentionally pull-based: a sleeping Mac cannot receive a push
/// command, and a stale status is safer than pretending that a command ran.
@MainActor
final class CompanionMacBridge {
    typealias StatusProvider = () -> CompanionMacStatus
    typealias HistoryProvider = () -> CompanionHistorySnapshot
    typealias CommandHandler = (CompanionRemoteCommand) -> CompanionRemoteResult

    private static let logger = Logger(
        subsystem: "lt.mantas.sleepswitch",
        category: "companion-sync"
    )
    private static let commandLedgerKey = "companion.command-ledger"
    private static let commandLedgerRetention: TimeInterval = 24 * 60 * 60
    private static let historyBuildInterval: TimeInterval = 60
    private static let commandCleanupInterval: TimeInterval = 6 * 60 * 60

    private let cloud: CompanionCloudStoring
    private let statusProvider: StatusProvider
    private let historyProvider: HistoryProvider
    private let commandHandler: CommandHandler
    private let defaults: UserDefaults
    private let statusHeartbeatInterval: TimeInterval
    private let historyHeartbeatInterval: TimeInterval
    private var timer: Timer?
    private var syncTask: Task<Void, Never>?
    private var commandLedger: [String: CommandLedgerEntry]
    private var lastStatusFingerprint: Data?
    private var lastHistoryFingerprint: Data?
    private var lastStatusPublishedAt: Date?
    private var lastHistoryPublishedAt: Date?
    private var cachedHistory: CompanionHistorySnapshot?
    private var lastHistoryBuiltAt: Date?
    private var lastCommandCleanupAt: Date?
    private var lastSyncStartedAt: Date?
    private let deviceIDValue: String

    private(set) var diagnostics = CompanionSyncDiagnostics() {
        didSet { onDiagnosticsChange?(diagnostics) }
    }
    var onDiagnosticsChange: ((CompanionSyncDiagnostics) -> Void)?

    var deviceID: String { deviceIDValue }


    init(
        cloud: CompanionCloudStoring = CompanionCloudStore(),
        deviceID: String = CompanionDeviceIdentity.load(key: "companionMacDeviceID"),
        statusProvider: @escaping StatusProvider,
        historyProvider: @escaping HistoryProvider,
        commandHandler: @escaping CommandHandler,
        defaults: UserDefaults = .standard,
        statusHeartbeatInterval: TimeInterval = 60,
        historyHeartbeatInterval: TimeInterval? = nil
    ) {
        self.cloud = cloud
        self.deviceIDValue = deviceID
        self.statusProvider = statusProvider
        self.historyProvider = historyProvider
        self.commandHandler = commandHandler
        self.defaults = defaults
        self.statusHeartbeatInterval = statusHeartbeatInterval
        self.historyHeartbeatInterval = historyHeartbeatInterval ?? statusHeartbeatInterval * 5
        self.commandLedger = Self.loadLedger(from: defaults)
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
        synchronize(force: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        syncTask?.cancel()
        syncTask = nil
    }

    func synchronize(force: Bool = false) {
        guard syncTask == nil else { return }
        let now = Date()
        if !force,
           let lastSyncStartedAt,
           now.timeIntervalSince(lastSyncStartedAt) < 5 {
            return
        }
        self.lastSyncStartedAt = now
        syncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.syncTask = nil }
            await self.performSynchronization(force: force)
        }
    }

    /// Runs one synchronization pass and suspends until all CloudKit work is
    /// complete. This is used by deterministic tests and lifecycle-aware
    /// callers; the menu-bar timer uses `synchronize()` above so it never
    /// blocks the UI event loop.
    func synchronizeAndWait(force: Bool = false) async {
        if let syncTask {
            await syncTask.value
            return
        }
        await performSynchronization(force: force)
    }

    private func performSynchronization(force: Bool) async {
        diagnostics.state = .syncing

        do {
            guard try await cloud.accountStatus() == .available else {
                markUnavailable()
                return
            }
        } catch {
            markFailure("Could not check the iCloud account status.", error: error)
            return
        }

        let now = Date()
        let status = statusProvider().refreshingLastSeen(at: now)
        let history: CompanionHistorySnapshot
        if !force,
           let cachedHistory,
           let lastHistoryBuiltAt,
           now.timeIntervalSince(lastHistoryBuiltAt) < Self.historyBuildInterval {
            history = cachedHistory
        } else {
            history = historyProvider()
            self.cachedHistory = history
            self.lastHistoryBuiltAt = now
        }
        let shouldPublishStatus = force || shouldPublishStatus(status, now: now)
        let shouldPublishHistory = force || shouldPublishHistory(history, now: now)
        var errors: [String] = []

        if shouldPublishStatus {
            do {
                try await cloud.publish(status: status)
                lastStatusFingerprint = statusFingerprint(status)
                lastStatusPublishedAt = now
                diagnostics.publishedStatusCount += 1
            } catch {
                errors.append(operationMessage("status", error: error))
            }
        }

        if shouldPublishHistory {
            do {
                try await cloud.publish(history: history)
                lastHistoryFingerprint = historyFingerprint(history)
                lastHistoryPublishedAt = now
                diagnostics.publishedHistoryCount += 1
            } catch {
                errors.append(operationMessage("history", error: error))
            }
        }

        do {
            let handledCommands = try await processPendingCommands()
            if handledCommands {
                let updatedStatus = statusProvider().refreshingLastSeen()
                try await cloud.publish(status: updatedStatus)
                lastStatusFingerprint = statusFingerprint(updatedStatus)
                lastStatusPublishedAt = Date()
                diagnostics.publishedStatusCount += 1
            }
        } catch {
            errors.append(operationMessage("remote commands", error: error))
        }

        if shouldPruneCommands(now: now) {
            do {
                _ = try await cloud.pruneCommands(
                    for: deviceIDValue,
                    before: now.addingTimeInterval(-Self.commandLedgerRetention)
                )
                lastCommandCleanupAt = now
            } catch {
                errors.append(operationMessage("command cleanup", error: error))
            }
        }

        if let issue = cloud.consumeLastIssue() {
            diagnostics.lastWarning = issue
        }

        if errors.isEmpty {
            markSuccess()
        } else {
            markFailure(errors.joined(separator: " "), error: nil)
        }
    }

    private func processPendingCommands() async throws -> Bool {
        let commands = try await cloud.fetchPendingCommands(for: deviceIDValue)
        for command in commands {
            if let decodeError = command.decodeError {
                try await cloud.reject(command: command, reason: decodeError)
                diagnostics.processedCommandCount += 1
                diagnostics.lastCommandAt = Date()
                continue
            }
            guard let commandValue = command.command else {
                try await cloud.reject(
                    command: command,
                    reason: "Sleep Switch could not read this remote command."
                )
                diagnostics.processedCommandCount += 1
                diagnostics.lastCommandAt = Date()
                continue
            }

            let result: CompanionRemoteResult
            if let entry = commandLedger[commandValue.nonce] {
                switch entry.phase {
                case .completed:
                    result = entry.result ?? CompanionRemoteResult(
                        commandID: commandValue.id,
                        accepted: false,
                        executed: false,
                        completedAt: Date(),
                        message: "The previous command result was unavailable. Sleep Switch did not repeat it."
                    )
                case .executing:
                    result = CompanionRemoteResult(
                        commandID: commandValue.id,
                        accepted: false,
                        executed: false,
                        completedAt: Date(),
                        message: "A previous attempt may have run. Sleep Switch did not repeat it."
                    )
                }
            } else {
                markCommandExecuting(commandValue)
                result = commandHandler(commandValue)
                markCommandCompleted(commandValue, result: result)
            }

            try await cloud.finish(command: command, result: result)
            diagnostics.processedCommandCount += 1
            diagnostics.lastCommandAt = Date()
        }
        return !commands.isEmpty
    }

    private func shouldPublishStatus(_ status: CompanionMacStatus, now: Date) -> Bool {
        guard let lastStatusFingerprint,
              let lastStatusPublishedAt
        else {
            return true
        }
        let equal = statusFingerprint(status) == lastStatusFingerprint
        return !equal
            || now.timeIntervalSince(lastStatusPublishedAt) >= statusHeartbeatInterval
    }

    private func shouldPublishHistory(_ history: CompanionHistorySnapshot, now: Date) -> Bool {
        guard let lastHistoryFingerprint,
              let lastHistoryPublishedAt
        else {
            return true
        }
        return historyFingerprint(history) != lastHistoryFingerprint
            || now.timeIntervalSince(lastHistoryPublishedAt) >= historyHeartbeatInterval
    }

    private func shouldPruneCommands(now: Date) -> Bool {
        guard let lastCommandCleanupAt else { return true }
        return now.timeIntervalSince(lastCommandCleanupAt) >= Self.commandCleanupInterval
    }

    private func statusFingerprint(_ status: CompanionMacStatus) -> Data {
        let normalized = status.refreshingLastSeen(at: Date(timeIntervalSince1970: 0))
        return (try? CompanionJSON.encoder.encode(normalized)) ?? Data()
    }

    private func historyFingerprint(_ history: CompanionHistorySnapshot) -> Data {
        let normalized = CompanionHistorySnapshot(
            deviceID: history.deviceID,
            updatedAt: Date(timeIntervalSince1970: 0),
            historyEnabled: history.historyEnabled,
            energyBuckets: history.energyBuckets,
            energyDays: history.energyDays,
            agentDays: history.agentDays,
            storageBytes: history.storageBytes
        )
        return (try? CompanionJSON.encoder.encode(normalized)) ?? Data()
    }

    private func markUnavailable() {
        diagnostics.state = .unavailable
        diagnostics.lastError = "iCloud is unavailable for this Mac."
        diagnostics.lastFailureAt = Date()
        diagnostics.consecutiveFailures += 1
    }

    private func markSuccess() {
        diagnostics.state = .succeeded
        diagnostics.lastSuccessAt = Date()
        diagnostics.lastError = nil
        diagnostics.consecutiveFailures = 0
    }

    private func markFailure(_ message: String, error: Error?) {
        diagnostics.state = .failed
        diagnostics.lastFailureAt = Date()
        diagnostics.lastError = error.map { operationMessage(message, error: $0) } ?? message
        diagnostics.consecutiveFailures += 1
        let logMessage = self.diagnostics.lastError ?? message
        Self.logger.error("\(logMessage, privacy: .public)")
    }

    private func operationMessage(_ operation: String, error: Error) -> String {
        "CloudKit " + operation + " sync failed: " + Self.redactedError(error)
    }

    private func operationMessage(_ operation: String, error: Error?) -> String {
        guard let error else { return operation }
        return operationMessage(operation, error: error)
    }

    private static func redactedError(_ error: Error) -> String {
        if let cloudError = error as? CKError {
            return "error \(cloudError.code.rawValue)"
        }
        return String(describing: type(of: error))
    }

    private func markCommandExecuting(_ command: CompanionRemoteCommand) {
        commandLedger[command.nonce] = CommandLedgerEntry(
            phase: .executing,
            result: nil,
            updatedAt: Date()
        )
        persistLedger()
    }

    private func markCommandCompleted(
        _ command: CompanionRemoteCommand,
        result: CompanionRemoteResult
    ) {
        commandLedger[command.nonce] = CommandLedgerEntry(
            phase: .completed,
            result: result,
            updatedAt: Date()
        )
        persistLedger()
    }

    private func persistLedger() {
        let cutoff = Date().addingTimeInterval(-Self.commandLedgerRetention)
        commandLedger = commandLedger.filter { $0.value.updatedAt >= cutoff }
        guard let data = try? CompanionJSON.encoder.encode(commandLedger) else { return }
        defaults.set(data, forKey: Self.commandLedgerKey)
    }

    private static func loadLedger(from defaults: UserDefaults) -> [String: CommandLedgerEntry] {
        guard let data = defaults.data(forKey: commandLedgerKey),
              let ledger = try? CompanionJSON.decoder.decode(
                [String: CommandLedgerEntry].self,
                from: data
              )
        else {
            return [:]
        }
        let cutoff = Date().addingTimeInterval(-commandLedgerRetention)
        return ledger.filter { $0.value.updatedAt >= cutoff }
    }
}

private struct CommandLedgerEntry: Codable {
    enum Phase: String, Codable {
        case executing
        case completed
    }

    let phase: Phase
    let result: CompanionRemoteResult?
    let updatedAt: Date
}
