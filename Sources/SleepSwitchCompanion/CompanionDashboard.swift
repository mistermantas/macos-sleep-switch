import Charts
import SwiftUI

struct CompanionDashboardRoot: View {
    @ObservedObject var model: CompanionAppModel
    @AppStorage("selectedMacDeviceID") private var selectedMacDeviceID = ""
    @State private var showingSettings = false
    @State private var pendingAction: CompanionRemoteAction?

    private var selectedMac: CompanionMacStatus? {
        model.macs.first(where: { $0.deviceID == selectedMacDeviceID }) ?? model.macs.first
    }

    @ViewBuilder
    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--screenshot-insights"),
           let mac = selectedMac,
           let history = model.history(for: mac) {
            NavigationStack {
                CompanionInsightsScreen(mac: mac, history: history)
            }
        } else if ProcessInfo.processInfo.arguments.contains("--screenshot-controls"),
                  let mac = selectedMac {
            NavigationStack {
                CompanionRemoteControlsScreen(mac: mac, model: model)
            }
        } else if ProcessInfo.processInfo.arguments.contains("--screenshot-settings") {
            CompanionPreferencesView(model: model) {}
        } else {
            rootContent
        }
        #else
        rootContent
        #endif
    }

    private var rootContent: some View {
        NavigationStack {
            Group {
                if let mac = selectedMac {
                    dashboard(mac)
                } else {
                    connectionState
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Sleep Switch")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        model.refresh()
                    }
                    .disabled(model.isLoading || model.commandInFlight)

                    Button("Settings", systemImage: "gearshape") {
                        showingSettings = true
                    }
                }
            }
            .refreshable { await model.refreshAndWait() }
            .task { await model.refreshAndWait() }
            .sheet(isPresented: $showingSettings) {
                CompanionPreferencesView(model: model) {
                    showingSettings = false
                }
            }
            .confirmationDialog(
                pendingAction?.title ?? "Confirm action",
                isPresented: Binding(
                    get: { pendingAction != nil },
                    set: { if !$0 { pendingAction = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let action = pendingAction, let mac = selectedMac {
                    Button(action.title, role: action.isDestructive ? .destructive : nil) {
                        pendingAction = nil
                        model.send(action, to: mac)
                    }
                }
                Button("Cancel", role: .cancel) { pendingAction = nil }
            }
        }
    }

    private func dashboard(_ mac: CompanionMacStatus) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                DeviceAndRefreshHeader(
                    macs: model.macs,
                    selectedMac: mac,
                    selectedDeviceID: $selectedMacDeviceID,
                    lastSyncAt: model.lastSyncAt
                )
                MacSnapshotCard(mac: mac)
                ManualSessionCard(mac: mac, model: model)
                PrimaryRemoteControls(
                    mac: mac,
                    model: model,
                    confirm: { pendingAction = $0 }
                )
                AgentAutomationCard(mac: mac, model: model)
                if mac.cooling != nil || mac.capabilities.canSetCoolingProfile == true {
                    CoolingControlCard(mac: mac, model: model)
                }
                if let history = model.history(for: mac) {
                    NavigationLink {
                        CompanionInsightsScreen(mac: mac, history: history)
                    } label: {
                        InsightsSummaryCard(mac: mac, history: history)
                    }
                    .buttonStyle(.plain)
                }
                NavigationLink {
                    CompanionRemoteControlsScreen(mac: mac, model: model)
                } label: {
                    NavigationRow(
                        title: "All Mac controls",
                        value: "Power, display and safety",
                        symbol: "switch.2"
                    )
                }
                if let message = model.message {
                    Label(message, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }

    private var connectionState: some View {
        ContentUnavailableView {
            Label(model.connectionTitle, systemImage: "icloud.slash")
        } description: {
            Text(model.connectionMessage)
        } actions: {
            Button("Retry", systemImage: "arrow.clockwise") { model.refresh() }
                .buttonStyle(.borderedProminent)
            Button("Connection Details", systemImage: "stethoscope") {
                showingSettings = true
            }
            .buttonStyle(.bordered)
        }
    }
}

private struct DeviceAndRefreshHeader: View {
    let macs: [CompanionMacStatus]
    let selectedMac: CompanionMacStatus
    @Binding var selectedDeviceID: String
    let lastSyncAt: Date?

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(macs) { mac in
                    Button {
                        selectedDeviceID = mac.deviceID
                    } label: {
                        Label(mac.displayName, systemImage: mac.id == selectedMac.id ? "checkmark" : "laptopcomputer")
                    }
                }
            } label: {
                Label(selectedMac.displayName, systemImage: "laptopcomputer")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text("Updated")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(lastSyncAt?.formatted(.relative(presentation: .named)) ?? "Never")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

        }
    }
}

private struct MacSnapshotCard: View {
    let mac: CompanionMacStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(mac.isStale ? "Last seen (mac.lastSeen.formatted(.relative(presentation: .named)))" : "Online")
                        .font(.headline)
                    Text(mac.build)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(mac.isStale ? Color.secondary : Color.green)
                    .frame(width: 10, height: 10)
            }

            HStack(spacing: 0) {
                SnapshotMetric(value: energyValue, label: energyLabel, symbol: "bolt.fill")
                Divider().frame(height: 42)
                SnapshotMetric(value: temperatureValue, label: thermalLabel, symbol: "thermometer.medium")
                Divider().frame(height: 42)
                SnapshotMetric(value: "\(mac.activeSessionCount)", label: agentLabel, symbol: "terminal")
            }

            HStack(spacing: 14) {
                Label(uptimeText, systemImage: "clock")
                if let battery = mac.batteryPercent {
                    Label("\(Int(battery.rounded()))%", systemImage: mac.isCharging ? "battery.100percent.bolt" : "battery.100percent")
                }
                Label(mac.displayAsleep ? "Display asleep" : "Display awake", systemImage: "display")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
    }

    private var energyValue: String {
        mac.estimatedWatts.map { "\(Int($0.rounded())) W" } ?? "—"
    }

    private var energyLabel: String {
        mac.estimatedWatts == nil ? "No reading" : "\(mac.energySource.title) · \(mac.energyConfidence.title.lowercased())"
    }

    private var temperatureValue: String {
        mac.cooling?.temperatureCelsius.map { "\(Int($0.rounded()))°" } ?? mac.thermalState.capitalized
    }

    private var thermalLabel: String {
        mac.cooling?.temperatureCelsius == nil ? "Thermal state" : mac.thermalState.capitalized
    }

    private var agentLabel: String {
        mac.activeSessionCount == 1 ? "Agent session" : "Agent sessions"
    }

    private var uptimeText: String {
        let hours = Int(mac.uptimeSeconds) / 3_600
        return hours >= 24 ? "Up \(hours / 24)d \(hours % 24)h" : "Up \(hours)h"
    }
}

private struct SnapshotMetric: View {
    let value: String
    let label: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(value, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }
}

private struct ManualSessionCard: View {
    let mac: CompanionMacStatus
    @ObservedObject var model: CompanionAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Manual session", systemImage: "cup.and.saucer.fill")
                    .font(.headline)
                Spacer()
                Text(mac.manualSession?.isActive == true ? remainingText : "Off")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(mac.manualSession?.isActive == true ? Color.green : Color.secondary)
            }

            if mac.manualSession?.isActive == true {
                Button("Stop Manual Session", systemImage: "stop.fill") {
                    model.send(.stopManualSession, to: mac)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Menu {
                    sessionButton("Indefinitely", seconds: nil)
                    sessionButton("30 Minutes", seconds: 30 * 60)
                    sessionButton("1 Hour", seconds: 60 * 60)
                    sessionButton("2 Hours", seconds: 2 * 60 * 60)
                    sessionButton("4 Hours", seconds: 4 * 60 * 60)
                } label: {
                    Label("Start Manual Session", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            Toggle("Keep Display Awake", isOn: Binding(
                get: { mac.keepDisplayAwake },
                set: { model.send(.setKeepAwake, to: mac, parameters: ["keepDisplayAwake": String($0)]) }
            ))
            .disabled(!mac.capabilities.canSetKeepAwake)

            if mac.capabilities.canPreventSleepWithLidClosed == true {
                Picker("Awake mode", selection: Binding(
                    get: { mac.awakeMode },
                    set: { model.send(.setKeepAwake, to: mac, parameters: ["awakeMode": $0]) }
                )) {
                    Text("Prevent Sleep").tag("preventSleep")
                    Text("Even Lid Closed").tag("lidClosed")
                }
                .pickerStyle(.segmented)
                .disabled(!mac.capabilities.canSetKeepAwake)
            }
        }
        .cardStyle()
        .disabled(mac.capabilities.canControlManualSession != true || mac.isStale || model.commandInFlight)
    }

    @ViewBuilder
    private func sessionButton(_ title: String, seconds: Int?) -> some View {
        Button(title) {
            var parameters: [String: String] = [:]
            if let seconds { parameters["durationSeconds"] = String(seconds) }
            model.send(.startManualSession, to: mac, parameters: parameters)
        }
    }

    private var remainingText: String {
        guard let end = mac.manualSession?.endsAt else { return "Running" }
        return end.formatted(.relative(presentation: .named))
    }
}

private struct PrimaryRemoteControls: View {
    let mac: CompanionMacStatus
    @ObservedObject var model: CompanionAppModel
    let confirm: (CompanionRemoteAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Display", systemImage: "display")
                .font(.headline)
            HStack(spacing: 10) {
                actionButton(.sleepDisplay, title: "Sleep display")
                actionButton(.sleepDisplayUntilAgentsFinish, title: "Until agents finish")
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private func actionButton(_ action: CompanionRemoteAction, title: String) -> some View {
        let supported = mac.capabilities.availableActions.contains(action)
        Button {
            if action.requiresConfirmation { confirm(action) } else { model.send(action, to: mac) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: action.symbolName)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(!supported || mac.isStale || model.commandInFlight)
    }
}

private struct AgentAutomationCard: View {
    let mac: CompanionMacStatus
    @ObservedObject var model: CompanionAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Agent automation", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                Text("\(mac.activeSessionCount) active")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let agents = mac.agents, !agents.isEmpty {
                HStack(spacing: 8) {
                    ForEach(agents) { agent in
                        Text("\(agent.name) · \(agent.sessionCount)")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.tint.opacity(0.12), in: Capsule())
                    }
                }
            }

            Toggle("Keep Awake for Agents", isOn: Binding(
                get: { mac.automaticAgentAwakeEnabled },
                set: { model.send(.setKeepAwake, to: mac, parameters: ["enabled": String($0)]) }
            ))
            Divider()
            Toggle("Wake Display When Agents Finish", isOn: Binding(
                get: { mac.wakeDisplayWhenAgentsFinish },
                set: { model.send(.setKeepAwake, to: mac, parameters: ["wakeWhenAgentsFinish": String($0)]) }
            ))
        }
        .cardStyle()
        .disabled(!mac.capabilities.canSetKeepAwake || mac.isStale || model.commandInFlight)
    }
}

private struct CoolingControlCard: View {
    let mac: CompanionMacStatus
    @ObservedObject var model: CompanionAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Cooling", systemImage: "fan")
                    .font(.headline)
                Spacer()
                Text(mac.cooling?.state ?? "Unavailable")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Picker("Cooling profile", selection: Binding(
                get: { mac.cooling?.profile ?? "systemControl" },
                set: { model.send(.setCoolingProfile, to: mac, parameters: ["profile": $0]) }
            )) {
                ForEach(availableProfiles, id: \.self) { profile in
                    Text(profileTitle(profile)).tag(profile)
                }
            }
            .pickerStyle(.segmented)
            .disabled(mac.capabilities.canSetCoolingProfile != true || mac.isStale || model.commandInFlight)

            if let cooling = mac.cooling {
                HStack(spacing: 16) {
                    if let temperature = cooling.temperatureCelsius {
                        Label("\(Int(temperature.rounded()))°C", systemImage: "thermometer.medium")
                    }
                    if !cooling.fans.isEmpty {
                        Label(fanSummary(cooling.fans), systemImage: "fan")
                    }
                    if let demand = cooling.verifiedDemand {
                        Label("\(Int((demand * 100).rounded()))%", systemImage: "gauge.with.dots.needle.50percent")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private func fanSummary(_ fans: [CompanionFanStatus]) -> String {
        let average = fans.map(\.actualRPM).reduce(0, +) / Double(fans.count)
        return "\(Int(average.rounded())) RPM"
    }

    private var availableProfiles: [String] {
        mac.cooling?.availableProfiles ?? ["systemControl"]
    }

    private func profileTitle(_ profile: String) -> String {
        switch profile {
        case "aggressive": "Aggressive"
        case "maximum": "Maximum"
        default: "System"
        }
    }
}

private struct InsightsSummaryCard: View {
    let mac: CompanionMacStatus
    let history: CompanionHistorySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Insights", systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 0) {
                SummaryValue(value: energyTotal, label: "Last 7 days")
                Divider().frame(height: 38)
                SummaryValue(value: agentHours, label: "Agent hours")
                Divider().frame(height: 38)
                SummaryValue(value: mac.estimatedWatts.map { "\(Int($0.rounded())) W" } ?? "—", label: "Now")
            }
        }
        .cardStyle()
    }

    private var energyTotal: String {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        let total = history.energyDays.filter { $0.dayStart >= cutoff }.reduce(0) { $0 + $1.kilowattHours }
        return String(format: "%.2f kWh", total)
    }

    private var agentHours: String {
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        let hours = history.agentDays.filter { $0.dayStart >= cutoff }.reduce(0) { $0 + $1.activeSeconds / 3_600 }
        return String(format: "%.1f h", hours)
    }
}

private struct SummaryValue: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.subheadline.weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }
}

private struct NavigationRow: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(value).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .cardStyle()
    }
}

struct CompanionInsightsScreen: View {
    let mac: CompanionMacStatus
    let history: CompanionHistorySnapshot
    @State private var range = CompanionInsightsRange.week
    @State private var metric = CompanionInsightsMetric.energy

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Metric", selection: $metric) {
                    ForEach(CompanionInsightsMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Range", selection: $range) {
                    ForEach(CompanionInsightsRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)

                if metric == .energy {
                    EnergyInsightsChart(mac: mac, history: history, range: range)
                } else {
                    AgentInsightsChart(mac: mac, history: history, range: range)
                }

                HStack {
                    Label("Updated \(history.updatedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: history.storageBytes, countStyle: .file))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum CompanionInsightsMetric: String, CaseIterable, Identifiable {
    case energy
    case agents
    var id: String { rawValue }
    var title: String { self == .energy ? "Energy" : "Agents" }
}

private enum CompanionInsightsRange: String, CaseIterable, Identifiable {
    case day
    case week
    case month
    var id: String { rawValue }
    var title: String { self == .day ? "24h" : self == .week ? "7 days" : "30 days" }
    var duration: TimeInterval { self == .day ? 86_400 : self == .week ? 7 * 86_400 : 30 * 86_400 }
}

private struct EnergyInsightsChart: View {
    let mac: CompanionMacStatus
    let history: CompanionHistorySnapshot
    let range: CompanionInsightsRange

    private var days: [CompanionEnergyDay] {
        history.energyDays.filter { $0.dayStart >= Date().addingTimeInterval(-range.duration) }
    }
    private var buckets: [EnergyBucket] {
        history.energyBuckets.filter { $0.bucketStart >= Date().addingTimeInterval(-range.duration) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 0) {
                SummaryValue(value: totalText, label: "Energy")
                Divider().frame(height: 38)
                SummaryValue(value: averageText, label: "Average draw")
                Divider().frame(height: 38)
                SummaryValue(value: peakText, label: "Peak draw")
            }

            if range == .day ? buckets.isEmpty : days.isEmpty {
                ContentUnavailableView("Energy history is building", systemImage: "bolt")
                    .frame(minHeight: 220)
            } else {
                Chart(range == .day ? buckets.map(EnergyChartPoint.init) : days.map(EnergyChartPoint.init)) { point in
                    BarMark(
                        x: .value("Time", point.date),
                        y: .value("Energy", point.kilowattHours)
                    )
                    .foregroundStyle(Color.blue.gradient)
                    .cornerRadius(3)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.22))
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(number.formatted(.number.precision(.fractionLength(2))))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: range == .day ? 4 : 6)) { value in
                        AxisGridLine().foregroundStyle(.clear)
                        AxisValueLabel(format: range == .day ? .dateTime.hour() : .dateTime.weekday(.abbreviated))
                    }
                }
                .frame(height: 240)
            }
        }
        .cardStyle()
    }

    private var totalText: String {
        let value = range == .day
            ? buckets.compactMap(\.kilowattHours).reduce(0, +)
            : days.reduce(0) { $0 + $1.kilowattHours }
        return String(format: "%.2f kWh", value)
    }
    private var averageText: String {
        let values = range == .day ? buckets.compactMap(\.averageWatts) : days.compactMap(\.averageWatts)
        guard !values.isEmpty else { return mac.estimatedWatts.map { "\(Int($0.rounded())) W" } ?? "—" }
        return "\(Int((values.reduce(0, +) / Double(values.count)).rounded())) W"
    }
    private var peakText: String {
        let peak = range == .day ? buckets.compactMap(\.peakWatts).max() : days.compactMap(\.peakWatts).max()
        return peak.map { "\(Int($0.rounded())) W" } ?? "—"
    }
}

private struct EnergyChartPoint: Identifiable {
    let date: Date
    let kilowattHours: Double
    var id: Date { date }
    init(_ day: CompanionEnergyDay) { date = day.dayStart; kilowattHours = day.kilowattHours }
    init(_ bucket: EnergyBucket) { date = bucket.bucketStart; kilowattHours = bucket.kilowattHours ?? 0 }
}

private struct AgentInsightsChart: View {
    let mac: CompanionMacStatus
    let history: CompanionHistorySnapshot
    let range: CompanionInsightsRange

    private var days: [CompanionAgentDay] {
        history.agentDays.filter { $0.dayStart >= Date().addingTimeInterval(-range.duration) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 0) {
                SummaryValue(value: String(format: "%.1f h", days.reduce(0) { $0 + $1.activeSeconds / 3_600 }), label: "Agent time")
                Divider().frame(height: 38)
                SummaryValue(value: "\(days.map(\.peakSessionCount).max() ?? 0)", label: "Peak sessions")
                Divider().frame(height: 38)
                SummaryValue(value: "\(mac.activeSessionCount)", label: "Active now")
            }

            if days.isEmpty {
                ContentUnavailableView("No agent activity in this range", systemImage: "terminal")
                    .frame(minHeight: 220)
            } else {
                Chart(days) { day in
                    BarMark(
                        x: .value("Day", day.dayStart),
                        y: .value("Hours", day.activeSeconds / 3_600)
                    )
                    .foregroundStyle(Color.orange.gradient)
                    .cornerRadius(3)
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.22))
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(number.formatted(.number.precision(.fractionLength(1))))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                    }
                }
                .frame(height: 240)
            }

            if let agents = mac.agents, !agents.isEmpty {
                Divider()
                ForEach(agents) { agent in
                    HStack {
                        Text(agent.name)
                        Spacer()
                        Text("\(agent.sessionCount) active")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
            }
        }
        .cardStyle()
    }
}

private struct CompanionRemoteControlsScreen: View {
    let mac: CompanionMacStatus
    @ObservedObject var model: CompanionAppModel
    @State private var pendingAction: CompanionRemoteAction?

    private let order: [CompanionRemoteAction] = [
        .sleepDisplay, .wakeDisplay, .sleepDisplayUntilAgentsFinish,
        .sleepMac, .lockMac, .restartMac, .shutdownMac, .panicStop
    ]

    var body: some View {
        List {
            Section("Available actions") {
                ForEach(order.filter { mac.capabilities.availableActions.contains($0) }, id: \.rawValue) { action in
                    Button {
                        if action.requiresConfirmation { pendingAction = action } else { model.send(action, to: mac) }
                    } label: {
                        Label(action.title, systemImage: action.symbolName)
                    }
                    .disabled(mac.isStale || model.commandInFlight)
                }
            }
        }
        .navigationTitle("Mac controls")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            pendingAction?.title ?? "Confirm action",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible
        ) {
            if let action = pendingAction {
                Button(action.title, role: action.isDestructive ? .destructive : nil) {
                    pendingAction = nil
                    model.send(action, to: mac)
                }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        }
    }
}

private struct CompanionPreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: CompanionAppModel
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    LabeledContent("Status", value: model.syncStage)
                    LabeledContent("Last checked", value: model.lastSyncAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                    ShareLink(item: model.diagnosticsReport) {
                        Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                    }
                }

                Section("Uncascade") {
                    Link(destination: AppLinks.uncascadeWebsite.url) {
                        Label("Uncascade Website", systemImage: "globe")
                    }
                    Link(destination: AppLinks.uncascadeYouTube.url) {
                        Label("Uncascade on YouTube", systemImage: "play.rectangle")
                    }
                    Link(destination: AppLinks.contactUncascade.url) {
                        Label("Contact Uncascade", systemImage: "envelope")
                    }
                }

                Section("Support") {
                    Link(destination: AppLinks.reportFeedback.url) {
                        Label("Report a Bug or Send Feedback", systemImage: "exclamationmark.bubble")
                    }
                    Link("Privacy Policy", destination: URL(string: "https://github.com/mistermantas/macos-sleep-switch/blob/main/PRIVACY.md")!)
                }

                Section("Credits") {
                    LabeledContent("Created and maintained by", value: "Mantas Vilčinskas")
                    LabeledContent("Copyright", value: "MB Uncascade")
                    LabeledContent("Version", value: AppLinks.currentVersionTitle)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone()
                        dismiss()
                    }
                }
            }
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
