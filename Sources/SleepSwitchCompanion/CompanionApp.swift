import CloudKit
import Charts
import SwiftUI

@main
struct SleepSwitchCompanionApp: App {
    @StateObject private var model = CompanionAppModel()

    var body: some Scene {
        WindowGroup {
            CompanionHomeView(model: model)
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

    private let cloud = CompanionCloudClient()
    private let requesterDeviceID = CompanionDeviceIdentity.load(key: "companionIOSDeviceID")

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        message = nil
        Task {
            let accountStatus = await cloud.accountStatus()
            self.accountStatus = accountStatus
            guard accountStatus == .available else {
                self.message = "Sign in to iCloud on this iPhone to see a paired Mac."
                self.macs = []
                self.isLoading = false
                return
            }
            do {
                self.macs = try await cloud.fetchMacs()
                var histories: [String: CompanionHistorySnapshot] = [:]
                for mac in self.macs {
                    if let history = try? await cloud.fetchHistory(for: mac.deviceID) {
                        histories[mac.deviceID] = history
                    }
                }
                self.histories = histories
                if self.macs.isEmpty {
                    self.message = "No Mac is paired yet. Open Sleep Switch on the Mac and keep it running."
                }
            } catch {
                self.message = "Could not read the private iCloud connection. Try again in a moment."
            }
            self.isLoading = false
        }
    }

    func history(for mac: CompanionMacStatus) -> CompanionHistorySnapshot? {
        histories[mac.deviceID]
    }

    func send(
        _ action: CompanionRemoteAction,
        to mac: CompanionMacStatus,
        parameters: [String: String] = [:]
    ) {
        guard !commandInFlight else { return }
        commandInFlight = true
        message = nil

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

        Task {
            do {
                try await cloud.send(command)
                self.message = "\(action.title) requested for \(mac.displayName)."
                try? await Task.sleep(for: .seconds(2))
                self.refresh()
            } catch {
                self.message = "Could not send \(action.title.lowercased()). \(error.localizedDescription)"
            }
            self.commandInFlight = false
        }
    }
}

struct CompanionHomeView: View {
    @ObservedObject var model: CompanionAppModel

    var body: some View {
        NavigationStack {
            List {
                if model.macs.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No paired Mac",
                            systemImage: "laptopcomputer",
                            description: Text(model.message ?? "Open Sleep Switch on the Mac to begin.")
                        )
                    }
                } else {
                    ForEach(model.macs) { mac in
                        MacDashboardView(mac: mac, model: model)
                    }
                }

                Section {
                    Label("Private iCloud connection", systemImage: "lock.icloud")
                    Text("Commands are short-lived, addressed to one Mac, and only work while Sleep Switch is running and the Mac is online.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Sleep Switch")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        model.refresh()
                    }
                    .disabled(model.isLoading || model.commandInFlight)
                }
            }
            .refreshable { model.refresh() }
            .safeAreaInset(edge: .bottom) {
                if let message = model.message {
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
            .task { model.refresh() }
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
