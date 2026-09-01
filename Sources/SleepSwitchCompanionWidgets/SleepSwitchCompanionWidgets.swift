import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SleepSwitchCompanionWidgets: WidgetBundle {
    var body: some Widget {
        SleepSwitchStatusWidget()
        if #available(iOS 16.2, *) {
            ManualSessionLiveActivity()
        }
    }
}

private struct SleepSwitchStatusEntry: TimelineEntry {
    let date: Date
    let snapshot: CompanionWidgetSnapshot?
}

private struct SleepSwitchStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> SleepSwitchStatusEntry {
        SleepSwitchStatusEntry(date: .now, snapshot: CompanionWidgetSnapshot(macName: "MacBook Pro", batteryPercent: 74, temperatureCelsius: 56, isCharging: true, activeSessionCount: 2, thermalState: "nominal", updatedAt: .now))
    }
    func getSnapshot(in context: Context, completion: @escaping (SleepSwitchStatusEntry) -> Void) {
        completion(SleepSwitchStatusEntry(date: .now, snapshot: CompanionWidgetStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SleepSwitchStatusEntry>) -> Void) {
        let entry = SleepSwitchStatusEntry(date: .now, snapshot: CompanionWidgetStore.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
    }
}

struct SleepSwitchStatusWidget: Widget {
    let kind = "SleepSwitchStatusWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SleepSwitchStatusProvider()) { entry in
            SleepSwitchWidgetView(entry: entry)
        }
        .configurationDisplayName("Mac status")
        .description("Battery, temperature, and active agent sessions from Sleep Switch.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}

private struct SleepSwitchWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SleepSwitchStatusEntry
    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .accessoryInline:
                Text("\(snapshot.macName): \(batteryText(snapshot)) · \(temperatureText(snapshot))")
            case .accessoryCircular:
                Gauge(value: snapshot.batteryPercent ?? 0, in: 0...100) { Image(systemName: "laptopcomputer") } currentValueLabel: { Text(snapshot.batteryPercent.map { "\(Int($0))" } ?? "–") }
            case .accessoryRectangular:
                HStack { Image(systemName: "laptopcomputer"); VStack(alignment: .leading) { Text(snapshot.macName).lineLimit(1); Text("\(batteryText(snapshot)) · \(temperatureText(snapshot))") } }
            default:
                VStack(alignment: .leading, spacing: 8) {
                    Label(snapshot.macName, systemImage: "laptopcomputer")
                        .font(.headline)
                        .lineLimit(1)
                    HStack { Label(batteryText(snapshot), systemImage: "battery.75percent"); Label(temperatureText(snapshot), systemImage: "thermometer.medium") }
                        .font(.caption.weight(.semibold))
                    Label("\(snapshot.activeSessionCount) agent \(snapshot.activeSessionCount == 1 ? "session" : "sessions")", systemImage: "terminal")
                        .font(.caption)
                    Spacer(minLength: 0)
                    Text(snapshot.updatedAt, style: .relative)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .containerBackground(for: .widget) { Color.black.opacity(0.001) }
            }
        } else {
            VStack { Image(systemName: "icloud.slash"); Text("Open Sleep Switch to connect your Mac") .font(.caption).multilineTextAlignment(.center) }
                .containerBackground(for: .widget) { Color.black.opacity(0.001) }
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
            .padding()
            .activityBackgroundTint(Color(.secondarySystemBackground))
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
