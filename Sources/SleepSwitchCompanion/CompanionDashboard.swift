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
        } else if ProcessInfo.processInfo.arguments.contains("--screenshot-mac-detail"),
                  let mac = selectedMac {
            NavigationStack {
                CompanionMacDetailScreen(mac: mac)
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
                NavigationLink {
                    CompanionMacDetailScreen(mac: mac)
                } label: {
                    MacSnapshotCard(mac: mac)
                }
                .buttonStyle(.plain)
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
                    Text(
                        mac.isStale
                            ? "Last seen \(mac.lastSeen.formatted(.relative(presentation: .named)))"
                            : "Online"
                    )
                        .font(.headline)
                    Text(mac.build)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(mac.isStale ? Color.secondary : Color.green)
                    .frame(width: 10, height: 10)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
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
                    Label("\(Int(battery.rounded()))%", systemImage: batterySymbol(for: battery))
                }
                if mac.isCharging {
                    Label(chargingText, systemImage: "bolt.fill")
                        .foregroundStyle(.green)
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

    private var chargingText: String {
        guard let watts = mac.chargingWatts, watts.isFinite else {
            return "Charging"
        }
        return "Charging · \(Int(watts.rounded())) W"
    }

    private func batterySymbol(for percentage: Double) -> String {
        switch max(0, min(100, percentage)) {
        case 88...:
            return "battery.100percent"
        case 63..<88:
            return "battery.75percent"
        case 38..<63:
            return "battery.50percent"
        case 13..<38:
            return "battery.25percent"
        default:
            return "battery.0percent"
        }
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

private struct CompanionMacDetailScreen: View {
    let mac: CompanionMacStatus

    private var sensors: [CompanionTemperatureSensor] {
        mac.cooling?.sensors ?? []
    }

    private var hottestTemperature: Double? {
        sensors.map(\.celsius).max() ?? mac.cooling?.temperatureCelsius
    }

    private var averageTemperature: Double? {
        guard !sensors.isEmpty else { return mac.cooling?.temperatureCelsius }
        return sensors.map(\.celsius).reduce(0, +) / Double(sensors.count)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 0) {
                    DetailMetric(
                        value: hottestTemperature.map(temperatureText) ?? "—",
                        label: "Hottest"
                    )
                    Divider().frame(height: 38)
                    DetailMetric(
                        value: averageTemperature.map(temperatureText) ?? "—",
                        label: "Average"
                    )
                    Divider().frame(height: 38)
                    DetailMetric(value: "\(sensors.count)", label: "Sensors")
                }
                .padding(.vertical, 6)

                LabeledContent("macOS thermal pressure", value: mac.thermalState.capitalized)
                if let state = mac.cooling?.state {
                    LabeledContent("Cooling", value: state)
                }
            } header: {
                Label("Thermals", systemImage: "thermometer.medium")
            }

            ForEach(CompanionTemperatureGroup.allCases, id: \.rawValue) { group in
                let groupSensors = sensors.filter { $0.group == group }
                if !groupSensors.isEmpty {
                    Section(group.title) {
                        ForEach(groupSensors) { sensor in
                            HStack {
                                Text(sensor.key)
                                    .font(.body.monospaced())
                                Spacer()
                                Text(temperatureText(sensor.celsius))
                                    .font(.body.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(temperatureColor(sensor.celsius))
                            }
                        }
                    }
                }
            }

            if let cooling = mac.cooling, !cooling.fans.isEmpty {
                Section {
                    ForEach(cooling.fans) { fan in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Fan \(fan.id + 1)")
                                Spacer()
                                Text("\(Int(fan.actualRPM.rounded())) RPM")
                                    .font(.body.monospacedDigit().weight(.semibold))
                            }
                            if let maximum = fan.maximumRPM, maximum > 0 {
                                ProgressView(value: min(1, fan.actualRPM / maximum))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Label("Fans", systemImage: "fan")
                }
            }

            Section {
                if let agents = mac.agents, !agents.isEmpty {
                    ForEach(agents) { agent in
                        LabeledContent(agent.name, value: "\(agent.sessionCount) running")
                    }
                } else {
                    Label("No agent sessions running", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Agents", systemImage: "terminal")
            }

            Section("Mac") {
                LabeledContent("Status", value: mac.isStale ? "Last seen \(mac.lastSeen.formatted(.relative(presentation: .named)))" : "Online")
                LabeledContent("Version", value: mac.build)
                LabeledContent("Display", value: mac.displayAsleep ? "Asleep" : "Awake")
                LabeledContent("Awake mode", value: awakeModeTitle)
                LabeledContent("Uptime", value: uptimeText)
                LabeledContent("Power", value: powerText)
            }
        }
        .navigationTitle(mac.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var awakeModeTitle: String {
        switch mac.awakeMode {
        case "lidClosed": "Even with lid closed"
        case "preventSleep": "Prevent sleep"
        default: mac.isKeepingAwake ? "Keeping awake" : "Follows macOS"
        }
    }

    private var uptimeText: String {
        let hours = Int(mac.uptimeSeconds) / 3_600
        return hours >= 24 ? "\(hours / 24)d \(hours % 24)h" : "\(hours)h"
    }

    private var powerText: String {
        guard let watts = mac.estimatedWatts else { return mac.energySource.title }
        return "\(Int(watts.rounded())) W · \(mac.energySource.title)"
    }

    private func temperatureText(_ value: Double) -> String {
        String(format: "%.1f°C", value)
    }

    private func temperatureColor(_ value: Double) -> Color {
        if value >= 85 { return .red }
        if value >= 70 { return .orange }
        return .primary
    }
}

private struct DetailMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                .disabled(!manualSessionAvailable)
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
                .disabled(!manualSessionAvailable)
            }

            if let unavailableReason {
                Label(unavailableReason, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Keep Display Awake", isOn: Binding(
                get: { mac.keepDisplayAwake },
                set: { model.send(.setKeepAwake, to: mac, parameters: ["keepDisplayAwake": String($0)]) }
            ))
            .disabled(!mac.capabilities.canSetKeepAwake || mac.isStale || model.commandInFlight)

            if mac.capabilities.canPreventSleepWithLidClosed == true {
                Picker("Awake mode", selection: Binding(
                    get: { mac.awakeMode },
                    set: { model.send(.setKeepAwake, to: mac, parameters: ["awakeMode": $0]) }
                )) {
                    Text("Prevent Sleep").tag("preventSleep")
                    Text("Even Lid Closed").tag("lidClosed")
                }
                .pickerStyle(.segmented)
                .disabled(!mac.capabilities.canSetKeepAwake || mac.isStale || model.commandInFlight)
            }
        }
        .cardStyle()
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

    private var manualSessionAvailable: Bool {
        mac.capabilities.canControlManualSession == true
            && !mac.isStale
            && !model.commandInFlight
    }

    private var unavailableReason: String? {
        if mac.isStale { return "Mac is offline" }
        if mac.capabilities.canControlManualSession != true {
            return "Update Sleep Switch on this Mac to enable remote sessions"
        }
        if model.commandInFlight { return "Waiting for the Mac" }
        return nil
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
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--screenshot-insights-day") {
                range = .day
            }
            #endif
        }
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
    @State private var selectedDate: Date?

    private let calendar = Calendar.autoupdatingCurrent

    private var days: [CompanionEnergyDay] {
        history.energyDays.filter { $0.dayStart >= Date().addingTimeInterval(-range.duration) }
    }
    private var buckets: [EnergyBucket] {
        history.energyBuckets.filter { $0.bucketStart >= Date().addingTimeInterval(-range.duration) }
    }
    private var dayPoints: [EnergyDayPoint] {
        let count = range == .week ? 7 : 30
        let today = calendar.startOfDay(for: Date())
        let indexed = Dictionary(uniqueKeysWithValues: days.map { (calendar.startOfDay(for: $0.dayStart), $0) })
        return (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - count + 1, to: today) else {
                return nil
            }
            return EnergyDayPoint(date: date, day: indexed[date])
        }
    }
    private var selectedBucket: EnergyBucket? {
        guard range == .day, let selectedDate else { return nil }
        guard let nearest = buckets.min(by: {
            abs($0.bucketStart.timeIntervalSince(selectedDate)) < abs($1.bucketStart.timeIntervalSince(selectedDate))
        }) else { return nil }
        let tolerance = max(TimeInterval(nearest.durationSeconds), 5 * 60)
        return abs(nearest.bucketStart.timeIntervalSince(selectedDate)) <= tolerance ? nearest : nil
    }
    private var selectedDayPoint: EnergyDayPoint? {
        guard range != .day, let selectedDate else { return nil }
        return dayPoints.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
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

            selectionInspector

            if range == .day ? buckets.isEmpty : days.isEmpty {
                ContentUnavailableView("Energy history is building", systemImage: "bolt")
                    .frame(minHeight: 220)
            } else {
                Chart {
                    energyChart
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
                    AxisMarks(values: axisDates) { value in
                        AxisGridLine().foregroundStyle(.clear)
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(axisLabel(for: date))
                            }
                        }
                    }
                }
                .chartXSelection(value: $selectedDate)
                .frame(height: 240)
            }

            Label(
                range == .day
                    ? "Touch and drag for five-minute readings"
                    : "Touch and drag for daily totals",
                systemImage: "hand.draw"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .cardStyle()
        .onAppear { selectLatest() }
        .onChange(of: range) { _, _ in selectLatest() }
    }

    @ChartContentBuilder
    private var energyChart: some ChartContent {
        if range == .day {
            ForEach(buckets) { bucket in
                BarMark(
                    x: .value("Time", bucket.bucketStart),
                    y: .value("Average watts", bucket.averageWatts ?? 0)
                )
                .foregroundStyle(
                    selectedBucket?.id == bucket.id
                        ? Color.cyan
                        : Color.blue
                )
                .cornerRadius(2)
            }
        } else {
            ForEach(dayPoints) { point in
                BarMark(
                    x: .value("Day", point.date),
                    y: .value("Energy", point.day?.kilowattHours ?? 0)
                )
                .foregroundStyle(
                    selectedDayPoint?.id == point.id
                        ? Color.cyan
                        : Color.blue
                )
                .opacity(point.day == nil ? 0 : 1)
                .cornerRadius(3)
            }
        }

        if let selectedDate {
            RuleMark(x: .value("Selected", selectedDate))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    @ViewBuilder
    private var selectionInspector: some View {
        if range == .day, let bucket = selectedBucket {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(bucketTime(bucket)).font(.headline)
                    Spacer()
                    Label(readingState(bucket), systemImage: readingStateSymbol(bucket))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 0) {
                    SummaryValue(value: bucket.averageWatts.map(wattsText) ?? "—", label: "Average")
                    Divider().frame(height: 34)
                    SummaryValue(value: bucket.peakWatts.map(wattsText) ?? "—", label: "Peak")
                    Divider().frame(height: 34)
                    SummaryValue(value: energyText(bucket.kilowattHours), label: "Energy")
                }
                HStack(spacing: 12) {
                    Label(bucket.source.title, systemImage: bucket.source == .battery ? "battery.75percent" : "powerplug")
                    Text(bucket.confidence.title)
                    Text("\(Int((bucket.coverage * 100).rounded()))% sampled")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if range == .day, let selectedDate {
            HStack(spacing: 12) {
                Image(systemName: "moon.zzz")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.headline)
                    Text("No report · asleep, off, or unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if range != .day, let point = selectedDayPoint {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(point.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.headline)
                    Spacer()
                    Text(point.day == nil ? "No report" : "Daily total")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 0) {
                    SummaryValue(value: point.day.map { String(format: "%.3f kWh", $0.kilowattHours) } ?? "—", label: "Energy")
                    Divider().frame(height: 34)
                    SummaryValue(value: point.day.flatMap(\.averageWatts).map(wattsText) ?? "—", label: "Average")
                    Divider().frame(height: 34)
                    SummaryValue(value: point.day.flatMap(\.peakWatts).map(wattsText) ?? "—", label: "Peak")
                }
            }
            .padding(12)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
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

    private var axisDates: [Date] {
        if range == .day {
            guard let first = buckets.first?.bucketStart, let last = buckets.last?.bucketStart else { return [] }
            return evenlySpacedDates(from: first, through: last, count: 4)
        }
        let points = dayPoints
        let desiredCount = range == .week ? 4 : 5
        guard !points.isEmpty else { return [] }
        return evenlySpacedIndices(total: points.count, count: desiredCount).map { points[$0].date }
    }

    private func axisLabel(for date: Date) -> String {
        if range == .day {
            return date.formatted(.dateTime.hour().minute())
        }
        if range == .week {
            return date.formatted(.dateTime.weekday(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func selectLatest() {
        selectedDate = range == .day ? buckets.last?.bucketStart : dayPoints.last?.date
    }

    private func readingState(_ bucket: EnergyBucket) -> String {
        let isCurrent = abs(history.updatedAt.timeIntervalSince(bucket.bucketStart)) < 10 * 60
        guard isCurrent else { return "Mac reporting" }
        if mac.displayAsleep { return "Display asleep" }
        if mac.isKeepingAwake { return "Kept awake" }
        return "Display awake"
    }

    private func readingStateSymbol(_ bucket: EnergyBucket) -> String {
        let state = readingState(bucket)
        if state == "Display asleep" { return "moon.fill" }
        if state == "Kept awake" { return "cup.and.saucer.fill" }
        if state == "Display awake" { return "display" }
        return "checkmark.circle"
    }

    private func bucketTime(_ bucket: EnergyBucket) -> String {
        let end = bucket.bucketStart.addingTimeInterval(TimeInterval(bucket.durationSeconds))
        return "\(bucket.bucketStart.formatted(date: .abbreviated, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }

    private func wattsText(_ watts: Double) -> String {
        String(format: "%.1f W", watts)
    }

    private func energyText(_ kilowattHours: Double?) -> String {
        guard let kilowattHours else { return "—" }
        return kilowattHours < 0.01
            ? String(format: "%.1f Wh", kilowattHours * 1_000)
            : String(format: "%.3f kWh", kilowattHours)
    }

    private func evenlySpacedDates(from start: Date, through end: Date, count: Int) -> [Date] {
        guard count > 1, end > start else { return [start] }
        return (0..<count).map { index in
            start.addingTimeInterval(end.timeIntervalSince(start) * Double(index) / Double(count - 1))
        }
    }

    private func evenlySpacedIndices(total: Int, count: Int) -> [Int] {
        guard total > 1, count > 1 else { return total == 0 ? [] : [0] }
        return Array(Set((0..<count).map { Int((Double($0) * Double(total - 1) / Double(count - 1)).rounded()) })).sorted()
    }
}

private struct EnergyDayPoint: Identifiable {
    let date: Date
    let day: CompanionEnergyDay?
    var id: Date { date }
}

private struct AgentInsightsChart: View {
    let mac: CompanionMacStatus
    let history: CompanionHistorySnapshot
    let range: CompanionInsightsRange
    @State private var selectedDate: Date?

    private let calendar = Calendar.autoupdatingCurrent

    private var days: [CompanionAgentDay] {
        history.agentDays.filter { $0.dayStart >= Date().addingTimeInterval(-range.duration) }
    }
    private var dayPoints: [AgentDayPoint] {
        let count = range == .day ? 1 : range == .week ? 7 : 30
        let today = calendar.startOfDay(for: Date())
        let indexed = Dictionary(uniqueKeysWithValues: days.map { (calendar.startOfDay(for: $0.dayStart), $0) })
        return (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset - count + 1, to: today) else {
                return nil
            }
            return AgentDayPoint(date: date, day: indexed[date])
        }
    }
    private var selectedPoint: AgentDayPoint? {
        guard let selectedDate else { return nil }
        return dayPoints.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
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

            if let point = selectedPoint {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(point.date.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .font(.headline)
                        Spacer()
                        Text(point.day == nil ? "No activity recorded" : "Daily total")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 0) {
                        SummaryValue(
                            value: point.day.map { String(format: "%.1f h", $0.activeSeconds / 3_600) } ?? "—",
                            label: "Agent time"
                        )
                        Divider().frame(height: 34)
                        SummaryValue(value: point.day.map { "\($0.peakSessionCount)" } ?? "—", label: "Peak sessions")
                        Divider().frame(height: 34)
                        SummaryValue(value: point.day.map { "\($0.agentCount)" } ?? "—", label: "Agents")
                    }
                }
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if days.isEmpty {
                ContentUnavailableView("No agent activity in this range", systemImage: "terminal")
                    .frame(minHeight: 220)
            } else {
                Chart {
                    ForEach(dayPoints) { point in
                        BarMark(
                            x: .value("Day", point.date),
                            y: .value("Hours", point.day.map { $0.activeSeconds / 3_600 } ?? 0)
                        )
                        .foregroundStyle(selectedPoint?.id == point.id ? Color.yellow : Color.orange)
                        .opacity(point.day == nil ? 0 : 1)
                        .cornerRadius(3)
                    }
                    if let selectedDate {
                        RuleMark(x: .value("Selected", selectedDate))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
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
                    AxisMarks(values: axisDates) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(axisLabel(for: date))
                            }
                        }
                    }
                }
                .chartXSelection(value: $selectedDate)
                .frame(height: 240)
            }

            Label("Touch and drag for daily activity", systemImage: "hand.draw")
                .font(.caption)
                .foregroundStyle(.secondary)

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
        .onAppear { selectedDate = dayPoints.last?.date }
        .onChange(of: range) { _, _ in selectedDate = dayPoints.last?.date }
    }

    private var axisDates: [Date] {
        let desiredCount = range == .month ? 5 : min(4, dayPoints.count)
        guard dayPoints.count > 1, desiredCount > 1 else { return dayPoints.map(\.date) }
        let indices = Array(Set((0..<desiredCount).map {
            Int((Double($0) * Double(dayPoints.count - 1) / Double(desiredCount - 1)).rounded())
        })).sorted()
        return indices.map { dayPoints[$0].date }
    }

    private func axisLabel(for date: Date) -> String {
        if range == .month { return date.formatted(.dateTime.month(.abbreviated).day()) }
        return date.formatted(.dateTime.weekday(.abbreviated).day())
    }
}

private struct AgentDayPoint: Identifiable {
    let date: Date
    let day: CompanionAgentDay?
    var id: Date { date }
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
