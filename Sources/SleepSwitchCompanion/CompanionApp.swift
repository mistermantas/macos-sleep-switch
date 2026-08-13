import CloudKit
import Charts
import SwiftUI

@main
struct SleepSwitchCompanionApp: App {
    @StateObject private var model = CompanionAppModel()

    var body: some Scene {
        WindowGroup {
            CompanionDashboardRoot(model: model)
        }
    }
}

@MainActor
final class CompanionAppModel: ObservableObject {
    @Published private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    @Published private(set) var macs: [CompanionMacStatus] = []
    @Published private(set) var histories: [String: CompanionHistorySnapshot] = [:]
    @Published private(set) var message: String?
    @Published private(set) var isLoading = false
    @Published private(set) var commandInFlight = false
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastSuccessfulSyncAt: Date?
    @Published private(set) var lastSyncIssue: String?
    @Published private(set) var lastConnectionError: CompanionConnectionError?
    @Published private(set) var syncStage = "Not checked"
    @Published private(set) var lastCommandStatus = "Never"

    private lazy var cloud = CompanionCloudClient()
    private let requesterDeviceID = CompanionDeviceIdentity.load(key: "companionIOSDeviceID")
    private var refreshTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?

    #if DEBUG
    private let isScreenshotDemo = ProcessInfo.processInfo.arguments.contains("--screenshot-demo")
    private let isConnectionDemo = ProcessInfo.processInfo.arguments.contains("--screenshot-connection")
    #endif

    init() {
        #if DEBUG
        if isScreenshotDemo {
            let demo = CompanionScreenshotDemo.make()
            macs = [demo.mac]
            histories = [demo.mac.deviceID: demo.history]
            message = "Demo data · connected to your private iCloud"
            lastSyncAt = Date()
            lastSuccessfulSyncAt = lastSyncAt
            syncStage = "Connected"
        } else if isConnectionDemo {
            accountStatus = .available
            lastSyncAt = Date()
            syncStage = "Connection failed"
            let error = NSError(
                domain: CKErrorDomain,
                code: CKError.networkFailure.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "The Internet connection appears to be offline."]
            )
            lastConnectionError = CompanionConnectionError(error: error)
            message = lastConnectionError?.userMessage
        }
        #endif
    }

    deinit {
        refreshTask?.cancel()
        commandTask?.cancel()
    }

    func refresh() {
#if targetEnvironment(simulator)
        showSimulatorCloudKitMessageIfNeeded()
#else
#if DEBUG
        if isScreenshotDemo || isConnectionDemo { return }
#endif
        guard !isLoading else { return }
        isLoading = true
        message = nil
        lastSyncIssue = nil
        syncStage = "Checking iCloud"
        refreshTask = Task { @MainActor [weak self] in
            await self?.performRefresh()
        }
#endif
    }

    func refreshAndWait() async {
#if targetEnvironment(simulator)
        showSimulatorCloudKitMessageIfNeeded()
#else
#if DEBUG
        if isScreenshotDemo || isConnectionDemo { return }
#endif
        if isLoading {
            if let refreshTask {
                await refreshTask.value
            }
            return
        }
        isLoading = true
        message = nil
        lastSyncIssue = nil
        syncStage = "Checking iCloud"
        await performRefresh()
#endif
    }

    private func performRefresh() async {
        defer {
            isLoading = false
            refreshTask = nil
        }

        do {
            let currentAccountStatus = try await cloud.accountStatus()
            accountStatus = currentAccountStatus
            guard currentAccountStatus == .available else {
                let issue = accountStatusMessage(for: currentAccountStatus)
                lastSyncIssue = issue
                lastConnectionError = CompanionConnectionError.account(
                    status: currentAccountStatus,
                    message: issue
                )
                message = issue
                macs = []
                histories = [:]
                lastSyncAt = Date()
                syncStage = "iCloud unavailable"
                return
            }

            syncStage = "Loading Macs"
            let fetchedMacs = try await cloud.fetchMacs()
            macs = fetchedMacs
            syncStage = "Loading history"
            let historyResults = await fetchHistories(for: fetchedMacs)
            histories = historyResults.histories
            lastSyncIssue = historyResults.issues.isEmpty
                ? cloud.consumeLastIssue()
                : historyResults.issues.joined(separator: " ")
            lastSyncAt = Date()
            lastSuccessfulSyncAt = lastSyncAt
            lastConnectionError = nil
            syncStage = "Connected"

            if fetchedMacs.isEmpty {
                message = "No Mac is paired yet. Open Sleep Switch on the Mac and keep it running."
            } else if !historyResults.issues.isEmpty {
                message = "Some history is unavailable. Refresh to try again."
            } else if let lastSyncIssue {
                message = lastSyncIssue
            }
        } catch is CancellationError {
            syncStage = "Cancelled"
            return
        } catch {
            let connectionError = CompanionConnectionError(error: error)
            lastConnectionError = connectionError
            lastSyncIssue = cloud.consumeLastIssue() ?? connectionError.summary
            lastSyncAt = Date()
            syncStage = "Connection failed"
            message = connectionError.userMessage
        }
    }

    private func fetchHistories(
        for macs: [CompanionMacStatus]
    ) async -> (
        histories: [String: CompanionHistorySnapshot],
        issues: [String]
    ) {
        let cloud = self.cloud
        return await withTaskGroup(of: HistoryFetchResult.self) { group in
            for mac in macs {
                group.addTask {
                    do {
                        let history = try await cloud.fetchHistory(for: mac.deviceID)
                        return HistoryFetchResult(
                            deviceID: mac.deviceID,
                            history: history,
                            issue: nil
                        )
                    } catch is CancellationError {
                        return HistoryFetchResult(
                            deviceID: mac.deviceID,
                            history: nil,
                            issue: "History loading was cancelled."
                        )
                    } catch {
                        return HistoryFetchResult(
                            deviceID: mac.deviceID,
                            history: nil,
                            issue: "History for \(mac.displayName) is unavailable."
                        )
                    }
                }
            }

            var histories: [String: CompanionHistorySnapshot] = [:]
            var issues: [String] = []
            for await result in group {
                if let history = result.history {
                    histories[result.deviceID] = history
                }
                if let issue = result.issue {
                    issues.append(issue)
                }
            }
            return (histories, issues)
        }
    }

    private func accountStatusMessage(for status: CKAccountStatus) -> String {
        switch status {
        case .available:
            return "iCloud is ready."
        case .noAccount:
            return "Sign in to iCloud on this iPhone to see a paired Mac."
        case .restricted:
            return "iCloud access is restricted on this iPhone."
        case .couldNotDetermine:
            return "Sleep Switch could not determine the iCloud account status."
        case .temporarilyUnavailable:
            return "iCloud is temporarily unavailable. Try again in a moment."
        @unknown default:
            return "Sleep Switch could not determine the iCloud account status."
        }
    }

    func history(for mac: CompanionMacStatus) -> CompanionHistorySnapshot? {
        histories[mac.deviceID]
    }

    var connectionTitle: String {
        if lastConnectionError != nil || accountStatus != .available {
            return "iCloud connection unavailable"
        }
        return "No paired Mac"
    }

    var connectionMessage: String {
        if let lastConnectionError {
            return lastConnectionError.userMessage
        }
        return message ?? "Open Sleep Switch on the Mac to begin."
    }

    var diagnosticsReport: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let checked = lastSyncAt?.formatted(date: .numeric, time: .standard) ?? "never"
        let succeeded = lastSuccessfulSyncAt?.formatted(date: .numeric, time: .standard) ?? "never"
        let error = lastConnectionError?.reportLines.joined(separator: "\n") ?? "Error: none"
        return """
        Sleep Switch Companion Diagnostics
        App: \(version) (\(build))
        CloudKit environment: \(Self.cloudEnvironmentName)
        Container: \(CompanionCloudStore.containerIdentifier)
        Account: \(accountStatus.diagnosticName)
        Stage: \(syncStage)
        Last checked: \(checked)
        Last successful sync: \(succeeded)
        Macs returned: \(macs.count)
        Last command: \(lastCommandStatus)
        \(error)
        """
    }

    static var cloudEnvironmentName: String {
        #if DEBUG
        return "Development"
        #else
        return "Production"
        #endif
    }

    func send(
        _ action: CompanionRemoteAction,
        to mac: CompanionMacStatus,
        parameters: [String: String] = [:]
    ) {
        guard !commandInFlight else { return }

#if targetEnvironment(simulator)
        applySimulatedCommand(action, to: mac, parameters: parameters)
#else
        commandInFlight = true
        message = nil
        lastCommandStatus = "Waiting — \(action.title)"

        let originalMac = mac
        if action == .setKeepAwake {
            replaceMac(mac.applyingKeepAwake(parameters: parameters))
        }

        let now = Date()
        let command = CompanionRemoteCommand(
            id: UUID(),
            targetDeviceID: mac.deviceID,
            action: action,
            parameters: parameters,
            requesterDeviceID: requesterDeviceID,
            nonce: UUID().uuidString,
            createdAt: now,
            expiresAt: now.addingTimeInterval(90),
            policyVersion: 1
        )

        commandTask?.cancel()
        commandTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.commandInFlight = false
                self.commandTask = nil
            }
            do {
                try await self.cloud.send(command)
                self.message = "\(action.title) requested for \(mac.displayName). Waiting for the Mac…"
                let result = try await self.waitForCommandResult(command.id)
                let completionMessage: String
                if let result {
                    completionMessage = result.message ?? (result.executed
                        ? "\(action.title) completed."
                        : "The Mac rejected \(action.title.lowercased()).")
                    self.lastCommandStatus = result.executed
                        ? "Completed — \(action.title)"
                        : "Rejected — \(action.title): \(completionMessage)"
                    if !result.executed, action == .setKeepAwake {
                        self.replaceMac(originalMac)
                    }
                } else {
                    completionMessage = "\(action.title) is still pending. The Mac may be asleep or offline."
                    self.lastCommandStatus = "Pending — \(action.title)"
                }
                if ![.sleepMac, .restartMac, .shutdownMac].contains(action) {
                    await self.refreshAndWait()
                }
                self.message = completionMessage
            } catch is CancellationError {
                return
            } catch {
                if action == .setKeepAwake {
                    self.replaceMac(originalMac)
                }
                let issue = CompanionConnectionError(error: error)
                self.lastCommandStatus = "Failed — \(action.title): \(issue.domain) \(issue.code)"
                self.lastSyncIssue = issue.userMessage
                self.message = "Could not send \(action.title.lowercased()). \(issue.recovery)"
            }
        }
#endif
    }

    private func replaceMac(_ updatedMac: CompanionMacStatus) {
        guard let index = macs.firstIndex(where: { $0.deviceID == updatedMac.deviceID }) else {
            return
        }
        macs[index] = updatedMac
    }

#if targetEnvironment(simulator)
    private func applySimulatedCommand(
        _ action: CompanionRemoteAction,
        to mac: CompanionMacStatus,
        parameters: [String: String]
    ) {
        if action == .setKeepAwake {
            replaceMac(mac.applyingKeepAwake(parameters: parameters))
        }
        lastCommandStatus = "Simulated — \(action.title)"
        message = "Simulated \(action.title.lowercased()). No command was sent to iCloud."
    }

    private func showSimulatorCloudKitMessageIfNeeded() {
#if DEBUG
        if isScreenshotDemo || isConnectionDemo { return }
#endif
        accountStatus = .couldNotDetermine
        syncStage = "Simulator"
        lastSyncAt = Date()
        message = "CloudKit pairing is unavailable in this unsigned Simulator build. Install the TestFlight app on an iPhone to control a Mac."
    }
#endif

    private func waitForCommandResult(_ commandID: UUID) async throws -> CompanionRemoteResult? {
        // The awake Mac intentionally polls CloudKit rather than relying on a
        // push wake. Allow two normal 15-second polling intervals before
        // presenting the command as pending.
        for _ in 0..<60 {
            try Task.checkCancellation()
            if let result = try await cloud.fetchResult(for: commandID) {
                return result
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return nil
    }

    private struct HistoryFetchResult {
        let deviceID: String
        let history: CompanionHistorySnapshot?
        let issue: String?
    }
}

struct CompanionConnectionError: Equatable {
    let domain: String
    let code: Int
    let summary: String
    let recovery: String
    let occurredAt: Date
    let retryAfter: TimeInterval?

    init(error: Error, occurredAt: Date = Date()) {
        let nsError = error as NSError
        domain = nsError.domain
        code = nsError.code
        summary = nsError.localizedDescription
        recovery = Self.recoveryMessage(for: error)
        self.occurredAt = occurredAt
        retryAfter = (nsError.userInfo[CKErrorRetryAfterKey] as? NSNumber)?.doubleValue
    }

    static func account(
        status: CKAccountStatus,
        message: String,
        occurredAt: Date = Date()
    ) -> CompanionConnectionError {
        CompanionConnectionError(
            domain: "CKAccountStatus",
            code: status.rawValue,
            summary: message,
            recovery: message,
            occurredAt: occurredAt,
            retryAfter: nil
        )
    }

    private init(
        domain: String,
        code: Int,
        summary: String,
        recovery: String,
        occurredAt: Date,
        retryAfter: TimeInterval?
    ) {
        self.domain = domain
        self.code = code
        self.summary = summary
        self.recovery = recovery
        self.occurredAt = occurredAt
        self.retryAfter = retryAfter
    }

    var userMessage: String { recovery }

    var reportLines: [String] {
        var lines = [
            "Error domain: \(domain)",
            "Error code: \(code)",
            "Error detail: \(summary)",
            "Error time: \(occurredAt.formatted(date: .numeric, time: .standard))"
        ]
        if let retryAfter {
            lines.append("Retry after: \(Int(retryAfter.rounded())) seconds")
        }
        return lines
    }

    private static func recoveryMessage(for error: Error) -> String {
        guard let cloudError = error as? CKError else {
            return "The private iCloud connection could not be read. Open Connection Details for the exact error."
        }
        switch cloudError.code {
        case .notAuthenticated:
            return "Sign in to iCloud on this iPhone, then retry."
        case .networkUnavailable, .networkFailure:
            return "The iCloud network connection is unavailable. Check your connection, then retry."
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return "iCloud is temporarily busy. Retry in a moment."
        case .permissionFailure:
            return "iCloud denied access to the private Sleep Switch data. Open Connection Details."
        case .unknownItem, .invalidArguments, .serverRejectedRequest:
            return "The CloudKit data setup does not match this build. Open Connection Details."
        default:
            return "The private iCloud connection could not be read. Open Connection Details for the exact error."
        }
    }
}

private extension CKAccountStatus {
    var diagnosticName: String {
        switch self {
        case .available: return "Available"
        case .noAccount: return "No account"
        case .restricted: return "Restricted"
        case .couldNotDetermine: return "Could not determine"
        case .temporarilyUnavailable: return "Temporarily unavailable"
        @unknown default: return "Unknown (\(rawValue))"
        }
    }
}

#if DEBUG
private enum CompanionScreenshotDemo {
    struct Snapshot {
        let mac: CompanionMacStatus
        let history: CompanionHistorySnapshot
    }

    static func make(now: Date = Date()) -> Snapshot {
        let calendar = Calendar.current
        let deviceID = "demo-macbook-pro"
        let capabilities = CompanionMacCapabilities(
            canSleepMac: true,
            canSleepDisplay: true,
            canWakeDisplay: true,
            canWakeMac: false,
            canLockMac: true,
            canRestartMac: true,
            canShutdownMac: true,
            canSetKeepAwake: true,
            canSleepDisplayUntilAgentsFinish: true,
            supportsCloudKit: true,
            canControlManualSession: true,
            canSetCoolingProfile: true,
            canPreventSleepWithLidClosed: true
        )
        let mac = CompanionMacStatus(
            deviceID: deviceID,
            displayName: "Mantas’ MacBook Pro",
            build: "2.3.0 (17)",
            lastSeen: now,
            uptimeSeconds: 2.4 * 24 * 3_600,
            powerSource: .ac,
            batteryPercent: 97,
            thermalState: "nominal",
            activeAgentCount: 3,
            activeSessionCount: 5,
            awakeMode: "agents",
            displayAsleep: false,
            isKeepingAwake: true,
            keepDisplayAwake: false,
            automaticAgentAwakeEnabled: true,
            wakeDisplayWhenAgentsFinish: false,
            estimatedWatts: 38,
            energySource: .ac,
            energyConfidence: .estimated,
            isCharging: true,
            chargingWatts: 31,
            capabilities: capabilities,
            agents: [
                CompanionAgentStatus(id: "codex", name: "Codex", sessionCount: 3),
                CompanionAgentStatus(id: "opencode", name: "OpenCode", sessionCount: 2)
            ],
            manualSession: nil,
            cooling: CompanionCoolingStatus(
                profile: "aggressive",
                state: "Aggressive",
                temperatureCelsius: 56,
                verifiedDemand: 0.72,
                fans: [
                    CompanionFanStatus(id: 0, actualRPM: 4_820, targetRPM: 4_900, maximumRPM: 6_200),
                    CompanionFanStatus(id: 1, actualRPM: 4_760, targetRPM: 4_900, maximumRPM: 6_200)
                ],
                message: nil,
                availableProfiles: ["systemControl", "aggressive", "maximum"]
            )
        )

        let energyDays = (0..<7).compactMap { offset -> CompanionEnergyDay? in
            guard let day = calendar.date(byAdding: .day, value: -6 + offset, to: calendar.startOfDay(for: now)) else { return nil }
            let values = [0.18, 0.24, 0.31, 0.27, 0.42, 0.36, 0.29]
            return CompanionEnergyDay(
                dayStart: day,
                kilowattHours: values[offset],
                averageWatts: 31 + Double(offset),
                peakWatts: 68 + Double(offset * 3),
                sampleCount: 48
            )
        }
        let agentDays = (0..<7).compactMap { offset -> CompanionAgentDay? in
            guard let day = calendar.date(byAdding: .day, value: -6 + offset, to: calendar.startOfDay(for: now)) else { return nil }
            return CompanionAgentDay(
                dayStart: day,
                activeSeconds: Double([3_600, 7_200, 10_800, 5_400, 14_400, 9_000, 11_700][offset]),
                peakSessionCount: [2, 3, 4, 3, 5, 4, 5][offset],
                agentCount: [1, 2, 3, 2, 4, 3, 3][offset]
            )
        }
        let history = CompanionHistorySnapshot(
            deviceID: deviceID,
            updatedAt: now,
            historyEnabled: true,
            energyBuckets: [],
            energyDays: energyDays,
            agentDays: agentDays,
            storageBytes: 92_160
        )
        return Snapshot(mac: mac, history: history)
    }
}
#endif

struct CompanionHomeView: View {
    @ObservedObject var model: CompanionAppModel
    @AppStorage("selectedMacDeviceID") private var selectedMacDeviceID = ""
    @AppStorage("showConnectionStatus") private var showConnectionStatus = true
    @State private var showingSettings = false

    private var selectedMac: CompanionMacStatus? {
        model.macs.first(where: { $0.deviceID == selectedMacDeviceID }) ?? model.macs.first
    }

    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--screenshot-settings") {
            NavigationStack {
                CompanionSettingsView(model: model)
            }
        } else if ProcessInfo.processInfo.arguments.contains("--screenshot-actions"), let mac = model.macs.first {
            NavigationStack {
                CompanionActionsView(mac: mac, model: model)
            }
        } else {
            dashboard
        }
        #else
        dashboard
        #endif
    }

    private var dashboard: some View {
        NavigationStack {
            ScrollView {
                if let mac = selectedMac {
                    VStack(alignment: .leading, spacing: 18) {
                        DeviceSelectorBar(
                            macs: model.macs,
                            selectedMac: mac,
                            selectedDeviceID: $selectedMacDeviceID
                        )
                        DeviceStatusCard(mac: mac)
                        AgentControlsCard(mac: mac, model: model)
                        QuickActionsCard(mac: mac, model: model)
                        if let history = model.history(for: mac) {
                            InsightsPreviewCard(history: history)
                        }
                        if showConnectionStatus {
                            ConnectionFooter(
                                lastSyncAt: model.lastSyncAt,
                                issue: model.lastSyncIssue
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                } else {
                    VStack(spacing: 20) {
                        ContentUnavailableView(
                            model.connectionTitle,
                            systemImage: model.lastConnectionError == nil
                                ? "laptopcomputer"
                                : "icloud.slash",
                            description: Text(model.connectionMessage)
                        )

                        HStack(spacing: 12) {
                            Button("Retry", systemImage: "arrow.clockwise") {
                                model.refresh()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isLoading)

                            Button("Connection Details", systemImage: "stethoscope") {
                                showingSettings = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 54)
                }
            }
            .scrollIndicators(.hidden)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Sleep Switch")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 14) {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            model.refresh()
                        }
                        .disabled(model.isLoading || model.commandInFlight)

                        Button("Settings", systemImage: "gearshape") {
                            showingSettings = true
                        }
                    }
                }
            }
            .refreshable { await model.refreshAndWait() }
            .safeAreaInset(edge: .bottom) {
                if selectedMac != nil, shouldShowMessage, let message = model.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(.bar)
                }
            }
            .task { await model.refreshAndWait() }
            .sheet(isPresented: $showingSettings) {
                CompanionSettingsView(
                    model: model,
                    onDone: { showingSettings = false }
                )
            }
        }
    }

    private var shouldShowMessage: Bool {
        #if DEBUG
        return !ProcessInfo.processInfo.arguments.contains("--screenshot-demo")
        #else
        return true
        #endif
    }
}

private struct DeviceSelectorBar: View {
    let macs: [CompanionMacStatus]
    let selectedMac: CompanionMacStatus
    @Binding var selectedDeviceID: String

    var body: some View {
        HStack(spacing: 12) {
            Label("Connected Mac", systemImage: "laptopcomputer")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Menu {
                ForEach(macs) { mac in
                    Button {
                        selectedDeviceID = mac.deviceID
                    } label: {
                        Label(
                            mac.displayName,
                            systemImage: mac.deviceID == selectedMac.deviceID ? "checkmark" : "laptopcomputer"
                        )
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selectedMac.displayName)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct DeviceStatusCard: View {
    let mac: CompanionMacStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "laptopcomputer")
                    .font(.title2)
                    .foregroundStyle(mac.isStale ? Color.secondary : Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(mac.displayName)
                        .font(.headline)
                    Text(mac.isStale ? "Last seen \(mac.lastSeen.formatted(date: .abbreviated, time: .shortened))" : "Online · Sleep Switch \(mac.build)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Circle()
                    .fill(mac.isStale ? Color.secondary : Color.green)
                    .frame(width: 10, height: 10)
                    .padding(.top, 6)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                MetricTile(title: "Uptime", value: uptimeText, symbol: "clock")
                MetricTile(title: "Energy", value: energyText, symbol: "bolt")
                MetricTile(title: "Thermal", value: mac.thermalState.capitalized, symbol: "thermometer.medium")
                MetricTile(title: "Agents", value: "\(mac.activeSessionCount) sessions", symbol: "terminal")
            }
        }
        .padding(18)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var uptimeText: String {
        let hours = Int(mac.uptimeSeconds) / 3_600
        let days = hours / 24
        if days > 0 { return "\(days)d \(hours % 24)h" }
        return "\(hours)h"
    }

    private var energyText: String {
        guard let watts = mac.estimatedWatts else { return "—" }
        return "\(Int(watts.rounded())) W"
    }
}

private struct AgentControlsCard: View {
    let mac: CompanionMacStatus
    @ObservedObject var model: CompanionAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Agent controls", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                Text("\(mac.activeAgentCount) active")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Toggle("Keep Awake for Agents", isOn: Binding(
                get: { mac.automaticAgentAwakeEnabled },
                set: { model.send(.setKeepAwake, to: mac, parameters: ["enabled": String($0)]) }
            ))
            .disabled(!mac.capabilities.canSetKeepAwake || mac.isStale || model.commandInFlight)

            Divider()

            Toggle("Wake Display When Agents Finish", isOn: Binding(
                get: { mac.wakeDisplayWhenAgentsFinish },
                set: { model.send(.setKeepAwake, to: mac, parameters: ["wakeWhenAgentsFinish": String($0)]) }
            ))
            .disabled(!mac.capabilities.canSetKeepAwake || mac.isStale || model.commandInFlight)
        }
        .padding(18)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct QuickActionsCard: View {
    let mac: CompanionMacStatus
    @ObservedObject var model: CompanionAppModel

    var body: some View {
        NavigationLink {
            CompanionActionsView(mac: mac, model: model)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Remote controls")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("\(mac.capabilities.availableActions.count) actions available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(18)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct InsightsPreviewCard: View {
    let history: CompanionHistorySnapshot

    private var energyTotal: Double {
        history.energyDays.reduce(0) { $0 + $1.kilowattHours }
    }

    private var agentHours: Double {
        history.agentDays.reduce(0) { $0 + $1.activeSeconds / 3_600 }
    }

    var body: some View {
        NavigationLink {
            CompanionHistoryView(history: history)
                .navigationTitle("Insights")
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Insights", systemImage: "chart.xyaxis.line")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }

                if history.historyEnabled, !history.energyDays.isEmpty {
                    Chart(history.energyDays) { day in
                        BarMark(
                            x: .value("Day", day.dayStart, unit: .day),
                            y: .value("kWh", day.kilowattHours)
                        )
                        .foregroundStyle(Color.accentColor.gradient)
                    }
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 84)

                    HStack(spacing: 16) {
                        Label(String(format: "%.2f kWh", energyTotal), systemImage: "bolt")
                        Label(String(format: "%.1f agent-hours", agentHours), systemImage: "terminal")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                } else {
                    Text("History saving is off on this Mac.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ConnectionFooter: View {
    let lastSyncAt: Date?
    let issue: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.icloud")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Private iCloud connection")
                    .font(.caption.weight(.semibold))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    private var statusText: String {
        if let issue {
            return issue
        }
        guard let lastSyncAt else {
            return "Commands are short-lived and addressed to one Mac."
        }
        return "Checked \(lastSyncAt.formatted(date: .omitted, time: .shortened)) · commands are short-lived."
    }
}

private struct CompanionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: CompanionAppModel
    private let onDone: (() -> Void)?
    @AppStorage("refreshOnOpen") private var refreshOnOpen = true
    @AppStorage("showConnectionStatus") private var showConnectionStatus = true

    init(model: CompanionAppModel, onDone: (() -> Void)? = nil) {
        self.model = model
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    Toggle("Refresh when opened", isOn: $refreshOnOpen)
                    Toggle("Show connection status", isOn: $showConnectionStatus)
                }

                Section("Connection details") {
                    LabeledContent("Status", value: model.syncStage)
                    LabeledContent("iCloud account", value: model.accountStatus.diagnosticName)
                    LabeledContent("Environment", value: CompanionAppModel.cloudEnvironmentName)
                    LabeledContent("Last checked", value: formatted(model.lastSyncAt))
                    LabeledContent("Last connected", value: formatted(model.lastSuccessfulSyncAt))

                    if let error = model.lastConnectionError {
                        DisclosureGroup("Last error · \(error.domain) \(error.code)") {
                            Text(error.summary)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ShareLink(
                        item: model.diagnosticsReport,
                        subject: Text("Sleep Switch connection diagnostics")
                    ) {
                        Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                    }
                }

                Section("Privacy") {
                    Label("Private iCloud", systemImage: "lock.icloud")
                    Text("The companion reads your Mac’s private CloudKit records. It does not use a developer-operated server.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    Link("Privacy policy", destination: URL(string: "https://github.com/mistermantas/macos-sleep-switch/blob/main/PRIVACY.md")!)
                    Link("Support & feedback", destination: URL(string: "https://github.com/mistermantas/macos-sleep-switch/issues")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onDone?()
                        dismiss()
                    }
                }
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    private func formatted(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
    }
}

#if DEBUG
private struct CompanionScreenshotActionsView: View {
    let mac: CompanionMacStatus

    private let actions: [CompanionRemoteAction] = [
        .sleepDisplay,
        .wakeDisplay,
        .sleepDisplayUntilAgentsFinish,
        .sleepMac,
        .lockMac,
        .restartMac,
        .shutdownMac
    ]

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "laptopcomputer")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Online")
                            .font(.headline)
                        Text("Mantas’ MacBook Pro · 5 agent sessions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(.green).frame(width: 10, height: 10)
                }
            }

            Section("Agent controls") {
                Toggle("Keep Awake for Agents", isOn: .constant(true))
                Toggle("Wake Display When Agents Finish", isOn: .constant(false))
            }

            Section {
                ForEach(actions, id: \.rawValue) { action in
                    Button {
                    } label: {
                        Label(action.title, systemImage: action.symbolName)
                    }
                }
            } header: {
                Text("Remote actions")
            } footer: {
                Text("Sleep Switch only sends named actions that this Mac has advertised. Sleep, lock, restart, and shutdown ask for confirmation.")
            }

            Section {
                Label("Private iCloud connection", systemImage: "lock.icloud")
                Text("Commands expire quickly and are addressed to this Mac. No developer-operated server is involved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sleep Switch")
    }
}
#endif

private struct CompanionActionsView: View {
    let mac: CompanionMacStatus
    @ObservedObject var model: CompanionAppModel
    @State private var actionAwaitingConfirmation: CompanionRemoteAction?

    private let actionOrder: [CompanionRemoteAction] = [
        .sleepDisplay,
        .wakeDisplay,
        .sleepDisplayUntilAgentsFinish,
        .sleepMac,
        .lockMac,
        .restartMac,
        .shutdownMac,
        .panicStop
    ]

    private var availableActions: [CompanionRemoteAction] {
        actionOrder.filter { mac.capabilities.availableActions.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "laptopcomputer")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(mac.displayName)
                            .font(.headline)
                        Text(mac.isStale ? "Offline" : "Online")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle()
                        .fill(mac.isStale ? Color.secondary : Color.green)
                        .frame(width: 10, height: 10)
                }
                .padding(18)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Power and display")
                        .font(.headline)
                    ForEach(availableActions, id: \.rawValue) { action in
                        Button {
                            if action.requiresConfirmation {
                                actionAwaitingConfirmation = action
                            } else {
                                model.send(action, to: mac)
                            }
                        } label: {
                            Label(action.title, systemImage: action.symbolName)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .disabled(mac.isStale || model.commandInFlight)
                    }
                }
                .padding(18)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))

                if !mac.capabilities.canWakeMac {
                    Label("Wake Mac is unavailable while it is fully asleep.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Remote controls")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            actionAwaitingConfirmation?.title ?? "Confirm action",
            isPresented: Binding(
                get: { actionAwaitingConfirmation != nil },
                set: { if !$0 { actionAwaitingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = actionAwaitingConfirmation {
                Button(action.title, role: action.isDestructive ? .destructive : nil) {
                    actionAwaitingConfirmation = nil
                    model.send(action, to: mac)
                }
            }
            Button("Cancel", role: .cancel) { actionAwaitingConfirmation = nil }
        } message: {
            if let action = actionAwaitingConfirmation {
                Text(confirmationMessage(for: action))
            }
        }
    }

    private func confirmationMessage(for action: CompanionRemoteAction) -> String {
        switch action {
        case .shutdownMac:
            return "The Mac will shut down. Any running work must already be saved."
        case .restartMac:
            return "The Mac will restart. Any running work must already be saved."
        case .sleepMac:
            return "The Mac will sleep. Sleep Switch will no longer receive commands until it wakes."
        case .sleepDisplay:
            return "Only the display will sleep; the Mac and its agents keep running."
        case .lockMac:
            return "The current macOS user session will be locked."
        default:
            return action.title
        }
    }
}

private struct MacDashboardView: View {
    let mac: CompanionMacStatus
    @ObservedObject var model: CompanionAppModel
    @State private var actionAwaitingConfirmation: CompanionRemoteAction?

    private let actionOrder: [CompanionRemoteAction] = [
        .sleepDisplay,
        .wakeDisplay,
        .sleepDisplayUntilAgentsFinish,
        .sleepMac,
        .lockMac,
        .restartMac,
        .shutdownMac,
        .panicStop
    ]

    private var availableActions: [CompanionRemoteAction] {
        actionOrder.filter { mac.capabilities.availableActions.contains($0) }
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                header
                metrics
                agentControls
                if let history = model.history(for: mac) {
                    CompanionHistoryView(history: history)
                }
                if availableActions.isEmpty {
                    Text("No remote power actions are available for this Mac build.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    powerActions
                }
                if !mac.capabilities.canWakeMac {
                    Text("Wake Mac is unavailable while the Mac is fully asleep. Sleep Switch must be running and awake to receive commands.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
        } header: {
            Text(mac.displayName)
        }
        .confirmationDialog(
            actionAwaitingConfirmation?.title ?? "Confirm action",
            isPresented: Binding(
                get: { actionAwaitingConfirmation != nil },
                set: { if !$0 { actionAwaitingConfirmation = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = actionAwaitingConfirmation {
                Button(action.title, role: action.isDestructive ? .destructive : nil) {
                    actionAwaitingConfirmation = nil
                    model.send(action, to: mac)
                }
            }
            Button("Cancel", role: .cancel) { actionAwaitingConfirmation = nil }
        } message: {
            if let action = actionAwaitingConfirmation {
                Text(confirmationMessage(for: action))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.title2)
                .foregroundStyle(mac.isStale ? .secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(mac.isStale ? "Last seen \(mac.lastSeen.formatted(date: .abbreviated, time: .shortened))" : "Online")
                    .font(.headline)
                Text("Sleep Switch \(mac.build)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(mac.isStale ? Color.secondary : Color.green)
                .frame(width: 10, height: 10)
                .padding(.top, 5)
        }
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MetricTile(title: "Uptime", value: uptimeText, symbol: "clock")
            MetricTile(title: "Energy", value: energyText, symbol: "bolt")
            MetricTile(title: "Thermal", value: mac.thermalState.capitalized, symbol: "thermometer.medium")
            MetricTile(title: "Agents", value: "\(mac.activeSessionCount) sessions", symbol: "terminal")
        }
    }

    private var agentControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Agent controls")
                .font(.subheadline.weight(.semibold))
            Toggle("Keep Awake for Agents", isOn: Binding(
                get: { mac.automaticAgentAwakeEnabled },
                set: { model.send(.setKeepAwake, to: mac, parameters: ["enabled": String($0)]) }
            ))
            .disabled(!mac.capabilities.canSetKeepAwake || mac.isStale || model.commandInFlight)
            Toggle("Wake Display When Agents Finish", isOn: Binding(
                get: { mac.wakeDisplayWhenAgentsFinish },
                set: { model.send(.setKeepAwake, to: mac, parameters: ["wakeWhenAgentsFinish": String($0)]) }
            ))
            .disabled(!mac.capabilities.canSetKeepAwake || mac.isStale || model.commandInFlight)
        }
    }

    private var powerActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Power actions")
                .font(.subheadline.weight(.semibold))
            ForEach(availableActions, id: \.rawValue) { action in
                Button {
                    if action.requiresConfirmation {
                        actionAwaitingConfirmation = action
                    } else {
                        model.send(action, to: mac)
                    }
                } label: {
                    Label(action.title, systemImage: action.symbolName)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(mac.isStale || model.commandInFlight)
            }
        }
    }

    private var uptimeText: String {
        let hours = Int(mac.uptimeSeconds) / 3_600
        let days = hours / 24
        if days > 0 { return "\(days)d \(hours % 24)h" }
        return "\(hours)h"
    }

    private var energyText: String {
        guard let watts = mac.estimatedWatts else { return "—" }
        return "\(Int(watts.rounded())) W"
    }

    private func confirmationMessage(for action: CompanionRemoteAction) -> String {
        switch action {
        case .shutdownMac:
            return "The Mac will shut down. Any running work must already be saved."
        case .restartMac:
            return "The Mac will restart. Any running work must already be saved."
        case .sleepMac:
            return "The Mac will sleep. Sleep Switch will no longer receive commands until it wakes."
        case .sleepDisplay:
            return "Only the display will sleep; the Mac and its agents keep running."
        case .lockMac:
            return "The current macOS user session will be locked."
        default:
            return action.title
        }
    }
}

private struct CompanionHistoryView: View {
    let history: CompanionHistorySnapshot
    @State private var range: CompanionHistoryRange = .week

    private var cutoff: Date {
        Date().addingTimeInterval(-range.duration)
    }

    private var energyDays: [CompanionEnergyDay] {
        history.energyDays.filter { $0.dayStart >= cutoff }
    }

    private var energyBuckets: [EnergyBucket] {
        history.energyBuckets.filter { $0.bucketStart >= cutoff }
    }

    private var agentDays: [CompanionAgentDay] {
        history.agentDays.filter { $0.dayStart >= cutoff }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("History")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(CompanionHistoryRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
            }

            if !history.historyEnabled {
                Label("History saving is off on this Mac.", systemImage: "chart.xyaxis.line")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Energy · kWh")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if range == .day ? energyBuckets.isEmpty : energyDays.isEmpty {
                    Text("Energy history is building.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if range == .day {
                    Chart(energyBuckets) { bucket in
                        BarMark(
                            x: .value("Time", bucket.bucketStart, unit: .hour),
                            y: .value("kWh", bucket.kilowattHours ?? 0)
                        )
                        .foregroundStyle(Color.accentColor.gradient)
                    }
                    .chartYAxisLabel("kWh")
                    .chartXAxis(.hidden)
                    .frame(height: 130)
                } else {
                    Chart(energyDays) { day in
                        BarMark(
                            x: .value("Day", day.dayStart, unit: .day),
                            y: .value("kWh", day.kilowattHours)
                        )
                        .foregroundStyle(Color.accentColor.gradient)
                    }
                    .chartYAxisLabel("kWh")
                    .chartXAxis(.hidden)
                    .frame(height: 130)
                }

                Text("Agent activity · hours")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if agentDays.isEmpty {
                    Text("No agent activity recorded for this range.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Chart(agentDays) { day in
                        BarMark(
                            x: .value("Day", day.dayStart, unit: .day),
                            y: .value("Hours", day.activeSeconds / 3_600)
                        )
                        .foregroundStyle(.orange.gradient)
                    }
                    .chartYAxisLabel("hours")
                    .chartXAxis(.hidden)
                    .frame(height: 130)
                }

                Text("Updated \(history.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
    }
}

private enum CompanionHistoryRange: String, CaseIterable, Identifiable {
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "24h"
        case .week: "7 days"
        case .month: "30 days"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .day: 24 * 60 * 60
        case .week: 7 * 24 * 60 * 60
        case .month: 30 * 24 * 60 * 60
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
