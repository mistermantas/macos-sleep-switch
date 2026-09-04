import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct SleepSwitchCompanionWidgets: WidgetBundle {
    var body: some Widget {
        SleepSwitchMetricWidget(kind: "SleepSwitchStatusWidget", displayName: "Mac status", description: "A compact view of your Mac, battery, thermals, and agents.", fixedMetric: nil)
        SleepSwitchMetricWidget(kind: "SleepSwitchBatteryWidget", displayName: "Mac battery", description: "Battery level and charging state from a Mac you choose.", fixedMetric: .battery)
        SleepSwitchMetricWidget(kind: "SleepSwitchThermalWidget", displayName: "Mac temperature", description: "Temperature, thermal state, and fan speed.", fixedMetric: .thermal)
        SleepSwitchMetricWidget(kind: "SleepSwitchFanWidget", displayName: "Mac fan", description: "The current highest fan speed on your Mac.", fixedMetric: .fan)
        SleepSwitchMetricWidget(kind: "SleepSwitchAgentsWidget", displayName: "Agent sessions", description: "How many agent sessions are currently running.", fixedMetric: .agents)
        SleepSwitchMetricWidget(kind: "SleepSwitchPowerWidget", displayName: "Mac power", description: "Charging state and the latest reading from your Mac.", fixedMetric: .power)
        SleepSwitchMetricWidget(kind: "SleepSwitchFreshnessWidget", displayName: "Mac connection", description: "When your Mac last checked in.", fixedMetric: .connection)
        if #available(iOS 16.2, *) { ManualSessionLiveActivity() }
    }
}

private enum SleepSwitchWidgetMetric {
    case overview, battery, thermal, fan, agents, power, connection
}

struct SleepSwitchWidgetMac: AppEntity, Identifiable {
    let id: String
    let name: String

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mac")
    static var defaultQuery = SleepSwitchWidgetMacQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name))
    }
}

struct SleepSwitchWidgetMacQuery: EntityQuery {
    func entities(for identifiers: [SleepSwitchWidgetMac.ID]) async throws -> [SleepSwitchWidgetMac] {
        availableMacs.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [SleepSwitchWidgetMac] { availableMacs }

    private var availableMacs: [SleepSwitchWidgetMac] {
        CompanionWidgetStore.loadAll().compactMap { snapshot in
            guard let id = snapshot.deviceID else { return nil }
            return SleepSwitchWidgetMac(id: id, name: snapshot.macName)
        }
    }
}

struct SleepSwitchWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Sleep Switch widget"
    static var description = IntentDescription("Choose the Mac this widget follows and whether its name appears.")

    @Parameter(title: "Computer") var mac: SleepSwitchWidgetMac?
    @Parameter(title: "Show computer name", default: true) var showMacName: Bool
}

private struct SleepSwitchStatusEntry: TimelineEntry {
    let date: Date
    let configuration: SleepSwitchWidgetConfigurationIntent
    let snapshot: CompanionWidgetSnapshot?
    let freshness: CompanionWidgetRefreshPlan.Freshness
    let freshnessLabel: String
}

private struct SleepSwitchStatusProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SleepSwitchStatusEntry {
        SleepSwitchStatusEntry(
            date: .now,
            configuration: SleepSwitchWidgetConfigurationIntent(),
            snapshot: CompanionWidgetSnapshot(macName: "MacBook Pro", batteryPercent: 74, temperatureCelsius: 56, fanRPM: 2_100, isCharging: true, activeSessionCount: 2, thermalState: "nominal", updatedAt: .now),
            freshness: .reporting,
            freshnessLabel: "Mac reporting"
        )
    }

    func snapshot(for configuration: SleepSwitchWidgetConfigurationIntent, in context: Context) async -> SleepSwitchStatusEntry {
        makeEntry(configuration: configuration)
    }

    func timeline(for configuration: SleepSwitchWidgetConfigurationIntent, in context: Context) async -> Timeline<SleepSwitchStatusEntry> {
        let entry = makeEntry(configuration: configuration)
        return Timeline(
            entries: [entry],
            policy: .after(entry.date.addingTimeInterval(CompanionWidgetRefreshPlan.fallbackRefreshInterval))
        )
    }

    private func makeEntry(configuration: SleepSwitchWidgetConfigurationIntent) -> SleepSwitchStatusEntry {
        let now = Date()
        let plan = CompanionWidgetRefreshPlan.make(
            snapshots: CompanionWidgetStore.loadAll(),
            configuredDeviceID: configuration.mac?.id,
            defaultDeviceID: CompanionWidgetStore.defaultDeviceID(),
            now: now
        )
        return SleepSwitchStatusEntry(
            date: now,
            configuration: configuration,
            snapshot: plan.snapshot,
            freshness: plan.freshness,
            freshnessLabel: plan.freshnessLabel
        )
    }
}

private struct SleepSwitchMetricWidget: Widget {
    let kind: String
    let displayName: LocalizedStringResource
    let description: LocalizedStringResource
    let fixedMetric: SleepSwitchWidgetMetric?

    init() {
        self.init(
            kind: "SleepSwitchStatusWidget",
            displayName: "Mac status",
            description: "A compact view of your Mac, battery, thermals, and agents.",
            fixedMetric: nil
        )
    }

    init(
        kind: String,
        displayName: LocalizedStringResource,
        description: LocalizedStringResource,
        fixedMetric: SleepSwitchWidgetMetric?
    ) {
        self.kind = kind
        self.displayName = displayName
        self.description = description
        self.fixedMetric = fixedMetric
    }

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SleepSwitchWidgetConfigurationIntent.self, provider: SleepSwitchStatusProvider()) { entry in
            SleepSwitchWidgetView(entry: entry, fixedMetric: fixedMetric)
        }
        .configurationDisplayName(displayName)
        .description(description)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}

private struct SleepSwitchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SleepSwitchStatusEntry
    let fixedMetric: SleepSwitchWidgetMetric?

    private var metric: SleepSwitchWidgetMetric { fixedMetric ?? .overview }

    var body: some View {
        Group {
            if let snapshot = entry.snapshot { content(snapshot) } else { emptyState }
        }
        .containerBackground(for: .widget) { Color.black.opacity(0.001) }
    }

    @ViewBuilder private func content(_ snapshot: CompanionWidgetSnapshot) -> some View {
        switch family {
        case .accessoryInline:
            Text(inlineText(snapshot))
        case .accessoryCircular:
            Gauge(value: gaugeValue(snapshot), in: 0...1) {
                Image(systemName: metricSymbol)
            } currentValueLabel: {
                Text(lockScreenValue(snapshot))
            }
            .gaugeStyle(.accessoryCircular)
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: metricSymbol)
                VStack(alignment: .leading, spacing: 2) {
                    if entry.configuration.showMacName { Text(snapshot.macName).lineLimit(1) }
                    Text(primaryValue(snapshot)).font(.headline)
                    Text(entry.freshnessLabel).font(.caption).foregroundStyle(freshnessColor)
                }
            }
        case .systemMedium, .systemLarge, .systemExtraLarge:
            wideContent(snapshot)
        default:
            compactContent(snapshot)
        }
    }

    private func compactContent(_ snapshot: CompanionWidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if entry.configuration.showMacName {
                Label(snapshot.macName, systemImage: "laptopcomputer").font(.caption.weight(.semibold)).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: metricSymbol).font(.title2).foregroundStyle(.tint)
            Text(primaryValue(snapshot)).font(.title3.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(secondaryValue(snapshot)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            Text(entry.freshnessLabel).font(.caption2).foregroundStyle(freshnessColor).lineLimit(1)
        }
    }

    private func wideContent(_ snapshot: CompanionWidgetSnapshot) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                if entry.configuration.showMacName {
                    Label(snapshot.macName, systemImage: "laptopcomputer").font(.caption.weight(.semibold)).lineLimit(1)
                }
                Text(primaryValue(snapshot)).font(.title2.weight(.bold)).monospacedDigit()
                Text(secondaryValue(snapshot)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(entry.freshnessLabel).font(.caption2).foregroundStyle(freshnessColor).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: metricSymbol)
                .font(.system(size: family == .systemLarge || family == .systemExtraLarge ? 44 : 34, weight: .medium))
                .foregroundStyle(.tint)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: entry.configuration.mac == nil ? "laptopcomputer.and.iphone" : "laptopcomputer.slash")
            Text(entry.configuration.mac == nil ? "Open Sleep Switch to choose a Mac" : "That Mac is no longer available")
                .font(.caption)
                .multilineTextAlignment(.center)
        }
    }

    private var freshnessColor: Color {
        switch entry.freshness {
        case .reporting, .recent, .noData: .secondary
        case .stale: .orange
        }
    }

    private var metricSymbol: String {
        switch metric {
        case .overview: "laptopcomputer"
        case .battery: "battery.75percent"
        case .thermal: "thermometer.medium"
        case .fan: "fan"
        case .agents: "terminal"
        case .power: "bolt.fill"
        case .connection: "icloud"
        }
    }

    private func primaryValue(_ snapshot: CompanionWidgetSnapshot) -> String {
        switch metric {
        case .overview, .battery: return batteryText(snapshot)
        case .thermal: return temperatureText(snapshot)
        case .fan: return snapshot.fanRPM.map { "\(Int($0.rounded())) RPM" } ?? "Fan —"
        case .agents: return "\(snapshot.activeSessionCount) \(snapshot.activeSessionCount == 1 ? "session" : "sessions")"
        case .power: return snapshot.isCharging ? "Charging" : "On battery"
        case .connection: return entry.freshness == .stale ? "Stale" : "Connected"
        }
    }

    private func secondaryValue(_ snapshot: CompanionWidgetSnapshot) -> String {
        switch metric {
        case .overview: return "\(temperatureText(snapshot)) · \(snapshot.activeSessionCount) agents"
        case .battery: return snapshot.isCharging ? "Charging now" : "Not charging"
        case .thermal: return snapshot.fanRPM.map { "Fan \(Int($0.rounded())) RPM" } ?? snapshot.thermalState.capitalized
        case .fan: return temperatureText(snapshot)
        case .agents: return snapshot.activeSessionCount == 0 ? "No active agents" : "Sleep Switch is keeping watch"
        case .power: return batteryText(snapshot)
        case .connection: return "Status from your Mac"
        }
    }

    private func inlineText(_ snapshot: CompanionWidgetSnapshot) -> String {
        let name = entry.configuration.showMacName ? "\(snapshot.macName): " : ""
        return "\(name)\(primaryValue(snapshot))"
    }

    private func lockScreenValue(_ snapshot: CompanionWidgetSnapshot) -> String {
        switch metric {
        case .battery, .overview: return snapshot.batteryPercent.map { "\(Int($0.rounded()))" } ?? "–"
        case .thermal: return snapshot.temperatureCelsius.map { "\(Int($0.rounded()))°" } ?? "–"
        case .fan: return snapshot.fanRPM.map { "\(Int($0.rounded() / 100))" } ?? "–"
        case .agents: return "\(snapshot.activeSessionCount)"
        case .power: return snapshot.isCharging ? "⚡" : "–"
        case .connection: return snapshot.updatedAt.timeIntervalSinceNow > -300 ? "●" : "–"
        }
    }

    private func gaugeValue(_ snapshot: CompanionWidgetSnapshot) -> Double {
        switch metric {
        case .battery, .overview, .power: return min(max((snapshot.batteryPercent ?? 0) / 100, 0), 1)
        case .thermal: return min(max((snapshot.temperatureCelsius ?? 20) / 100, 0), 1)
        case .fan: return min(max((snapshot.fanRPM ?? 0) / 6_000, 0), 1)
        case .agents: return min(Double(snapshot.activeSessionCount) / 8, 1)
        case .connection: return snapshot.updatedAt.timeIntervalSinceNow > -300 ? 1 : 0.2
        }
    }

    private func batteryText(_ value: CompanionWidgetSnapshot) -> String { value.batteryPercent.map { "\(Int($0.rounded()))%" } ?? "Battery —" }
    private func temperatureText(_ value: CompanionWidgetSnapshot) -> String { value.temperatureCelsius.map { "\(Int($0.rounded()))°C" } ?? value.thermalState.capitalized }
}

@available(iOS 16.2, *)
private struct ManualSessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ManualSessionActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "cup.and.saucer.fill").foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(context.attributes.macName).font(.headline)
                    Text("Manual session active").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                sessionTimer(context.state)
            }
            .padding().activityBackgroundTint(Color(.secondarySystemBackground))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "cup.and.saucer.fill") }
                DynamicIslandExpandedRegion(.center) { Text(context.attributes.macName).lineLimit(1) }
                DynamicIslandExpandedRegion(.trailing) { sessionTimer(context.state) }
                DynamicIslandExpandedRegion(.bottom) { Text("Sleep Switch manual session") }
            } compactLeading: { Image(systemName: "cup.and.saucer.fill") } compactTrailing: { sessionTimer(context.state) } minimal: { Image(systemName: "cup.and.saucer.fill") }
        }
    }

    @ViewBuilder private func sessionTimer(_ state: ManualSessionActivityAttributes.ContentState) -> some View {
        if let endsAt = state.endsAt { Text(timerInterval: .now...endsAt, countsDown: true).monospacedDigit() } else { Text("On") }
    }
}
