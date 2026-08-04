import AppKit
import Charts
import SwiftUI

@MainActor
final class InsightsViewModel: ObservableObject {
    @Published var range: InsightsRange = .live
    @Published var tab: InsightsTab = .energy
    @Published private(set) var snapshot: InsightsSnapshot
    @Published var showingDeleteConfirmation = false

    let recorder: InsightsRecorder

    init(recorder: InsightsRecorder) {
        self.recorder = recorder
        self.snapshot = recorder.snapshot(for: .live)
        recorder.onChange = { [weak self] snapshot in
            guard let self else { return }
            self.snapshot = snapshot
        }
    }

    var totalKilowattHours: Double {
        snapshot.buckets.compactMap(\.kilowattHours).reduce(0, +)
    }

    var latestReading: EnergyReading? {
        recorder.latestReading
    }

    func refresh() {
        snapshot = recorder.snapshot(for: range)
    }

    func setHistoryEnabled(_ enabled: Bool) {
        recorder.setHistoryEnabled(enabled)
        refresh()
    }

    func deleteHistory() {
        try? recorder.deleteHistory()
        refresh()
    }
}

enum InsightsTab: String, CaseIterable, Identifiable {
    case energy
    case agents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .energy:
            return "Energy"
        case .agents:
            return "Agent activity"
        }
    }
}

@MainActor
final class InsightsWindowController: NSWindowController {
    private let viewModel: InsightsViewModel

    init(recorder: InsightsRecorder) {
        viewModel = InsightsViewModel(recorder: recorder)
        let content = InsightsView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Insights · Sleep Switch"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 560))
        window.minSize = NSSize(width: 560, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        shouldCascadeWindows = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        viewModel.refresh()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct InsightsView: View {
    @ObservedObject var viewModel: InsightsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Picker("View", selection: $viewModel.tab) {
                ForEach(InsightsTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 22)
            .padding(.top, 16)

            Group {
                switch viewModel.tab {
                case .energy:
                    EnergyInsightsView(viewModel: viewModel)
                case .agents:
                    AgentInsightsView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(
            "Delete local history?",
            isPresented: $viewModel.showingDeleteConfirmation
        ) {
            Button("Delete", role: .destructive) {
                viewModel.deleteHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Energy buckets and agent activity intervals will be removed from this Mac.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Insights")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("A quiet view of what happened while work ran.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Range", selection: $viewModel.range) {
                ForEach(InsightsRange.allCases) { range in
                    Text(range.title).tag(range)
                }
            }
            .labelsHidden()
            .onChange(of: viewModel.range) { _ in
                viewModel.refresh()
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 6)
    }
}

private struct EnergyInsightsView: View {
    @ObservedObject var viewModel: InsightsViewModel

    private var buckets: [EnergyBucket] { viewModel.snapshot.buckets }
    private var plottedPoints: [PowerPoint] {
        if viewModel.range == .live {
            return viewModel.snapshot.energy.compactMap { reading in
                guard let watts = reading.watts, watts.isFinite, watts >= 0 else { return nil }
                return PowerPoint(date: reading.recordedAt, watts: watts)
            }
        }
        return buckets.compactMap { bucket in
            guard let watts = bucket.averageWatts else { return nil }
            return PowerPoint(date: bucket.bucketStart, watts: watts)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                metric(title: "Estimated energy", value: energyText)
                metric(title: "Latest reading", value: latestText)
                metric(title: "Source", value: sourceText)
                Spacer()
            }

            if plottedPoints.isEmpty {
                EmptyInsightsState(
                    symbol: "chart.xyaxis.line",
                    title: "Energy history is building",
                    message: "Keep Sleep Switch open for a few minutes to see a five-minute energy bucket."
                )
            } else {
                Chart(plottedPoints) { point in
                    AreaMark(
                        x: .value("Time", point.date),
                        y: .value("Power", point.watts)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.accentColor.opacity(0.34), .accentColor.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Power", point.watts)
                    )
                    .foregroundStyle(Color.accentColor)
                }
                .chartYAxisLabel("Watts")
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5))
                }
                .chartYScale(domain: 0...max(20, (plottedPoints.map(\.watts).max() ?? 20) * 1.15))
                .frame(minHeight: 250)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Estimated power over time")
            }

            footer
        }
        .padding(22)
    }

    private var energyText: String {
        let total = viewModel.totalKilowattHours
        guard total > 0 else { return "—" }
        return String(format: "%.3f kWh", total)
    }

    private var latestText: String {
        guard let latest = viewModel.latestReading else { return "—" }
        return latest.displayWatts
    }

    private var sourceText: String {
        guard let latest = viewModel.latestReading else { return "Waiting" }
        return latest.confidence == .unavailable
            ? "\(latest.source.title)"
            : "\(latest.source.title) · \(latest.confidence.title.lowercased())"
    }

    private var footer: some View {
        HStack {
            Toggle(
                "Save energy and agent history",
                isOn: Binding(
                    get: { viewModel.snapshot.historyEnabled },
                    set: { viewModel.setHistoryEnabled($0) }
                )
            )
            .toggleStyle(.checkbox)
            Text(storageText)
                .foregroundStyle(.secondary)
                .font(.caption)
            Spacer()
            Button("Delete History…") {
                viewModel.showingDeleteConfirmation = true
            }
            .buttonStyle(.link)
        }
        .font(.caption)
        .padding(.top, 2)
    }

    private var storageText: String {
        let bytes = viewModel.snapshot.storageBytes
        guard bytes > 0 else { return "Local history is empty" }
        return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) on this Mac"
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold))
        }
        .frame(minWidth: 118, alignment: .leading)
    }
}

private struct AgentInsightsView: View {
    @ObservedObject var viewModel: InsightsViewModel

    private var intervals: [AgentActivityInterval] {
        AgentActivityWindow.overnight(viewModel.snapshot.activities)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Overnight activity")
                        .font(.headline)
                    Text("18:00–12:00 local time · prompts and file paths stay local")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(summaryText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if intervals.isEmpty {
                EmptyInsightsState(
                    symbol: "terminal",
                    title: "No agent activity yet",
                    message: "Supported agents appear here when Sleep Switch sees them working."
                )
            } else {
                Chart(intervals) { interval in
                    RectangleMark(
                        xStart: .value("Start", interval.startedAt),
                        xEnd: .value("End", interval.effectiveEnd),
                        y: .value("Agent", interval.agentName)
                    )
                    .foregroundStyle(interval.state == .running ? Color.orange : Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5))
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(minHeight: 280)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Agent activity intervals")
            }

            HStack {
                Image(systemName: "info.circle")
                Text("Running intervals are still active. A quiet gap means the tracker did not observe an agent, not that work definitely stopped.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(22)
    }

    private var summaryText: String {
        let sessions = intervals.count
        let agents = Set(intervals.map(\.agentID)).count
        return "\(agents) agent\(agents == 1 ? "" : "s") · \(sessions) interval\(sessions == 1 ? "" : "s")"
    }
}

private struct PowerPoint: Identifiable {
    let date: Date
    let watts: Double

    var id: Date { date }
}

private struct EmptyInsightsState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 390)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }
}
