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
        window.setContentSize(NSSize(width: 900, height: 680))
        window.minSize = NSSize(width: 720, height: 540)
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
            HStack(spacing: 10) {
                Label("View", systemImage: "chart.xyaxis.line")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("View", selection: $viewModel.tab) {
                    ForEach(InsightsTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Choose the activity you want to inspect")
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)

            ScrollView {
                Group {
                    switch viewModel.tab {
                    case .energy:
                        EnergyInsightsView(viewModel: viewModel)
                    case .agents:
                        AgentInsightsView(viewModel: viewModel)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
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
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("A quiet view of what happened while work ran.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                ForEach(InsightsRange.allCases) { range in
                    Button {
                        viewModel.range = range
                        viewModel.refresh()
                    } label: {
                        if range == viewModel.range {
                            Label(range.title, systemImage: "checkmark")
                        } else {
                            Text(range.title)
                        }
                    }
                }
            } label: {
                Label(viewModel.range.title, systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .help("Choose the time range")
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

private struct EnergyInsightsView: View {
    @ObservedObject var viewModel: InsightsViewModel
    @State private var focusedDate: Date?

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
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Energy use")
                        .font(.title3.weight(.bold))
                    Text("Estimated power drawn by this Mac")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(updatedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                spacing: 10
            ) {
                metric(
                    title: "Estimated energy",
                    value: energyText,
                    detail: viewModel.range == .live ? "last 24 hours" : viewModel.range.title.lowercased(),
                    systemImage: "bolt.fill",
                    tint: .orange
                )
                metric(
                    title: "Latest reading",
                    value: latestText,
                    detail: sourceText,
                    systemImage: "gauge.with.dots.needle.67percent",
                    tint: .accentColor
                )
                metric(
                    title: "Samples",
                    value: "\(plottedPoints.count)",
                    detail: viewModel.snapshot.historyEnabled ? "saved locally" : "history off",
                    systemImage: "waveform.path.ecg",
                    tint: .green
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Power over time")
                        .font(.headline)
                    Spacer()
                    Text("Watts")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if plottedPoints.isEmpty {
                    EmptyInsightsState(
                        symbol: "chart.xyaxis.line",
                        title: "Energy history is building",
                        message: "Keep Sleep Switch open for a few minutes to see a five-minute energy bucket."
                    )
                    .frame(height: 230)
                } else {
                    Chart {
                        ForEach(plottedPoints) { point in
                            AreaMark(
                                x: .value("Time", point.date),
                                y: .value("Power", point.watts)
                            )
                            .foregroundStyle(
                                .linearGradient(
                                    colors: [.accentColor.opacity(0.30), .accentColor.opacity(0.03)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Power", point.watts)
                            )
                            .foregroundStyle(Color.accentColor)
                            .interpolationMethod(.catmullRom)
                        }

                        if let focusedPoint {
                            RuleMark(x: .value("Selected time", focusedPoint.date))
                                .foregroundStyle(.secondary.opacity(0.7))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            PointMark(
                                x: .value("Selected time", focusedPoint.date),
                                y: .value("Selected power", focusedPoint.watts)
                            )
                            .foregroundStyle(Color.accentColor)
                            .symbolSize(70)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5))
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                                .foregroundStyle(.secondary.opacity(0.22))
                            AxisValueLabel()
                        }
                    }
                    .chartYScale(domain: 0...max(20, (plottedPoints.map(\.watts).max() ?? 20) * 1.15))
                    .chartPlotStyle { plotArea in
                        plotArea
                            .background(Color.accentColor.opacity(0.035))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(.clear)
                                .contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        focusedDate = pointDate(at: location, proxy: proxy, geometry: geometry)
                                    case .ended:
                                        focusedDate = nil
                                    }
                                }
                                .onTapGesture { location in
                                    focusedDate = pointDate(at: location, proxy: proxy, geometry: geometry)
                                }
                        }
                    }
                    .frame(height: 250)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Estimated power over time")

                    if let focusedPoint {
                        HStack(spacing: 8) {
                            Image(systemName: "cursorarrow.rays")
                                .foregroundStyle(Color.accentColor)
                            Text(focusedPoint.date.formatted(date: .abbreviated, time: .shortened))
                            Text("•")
                                .foregroundStyle(.tertiary)
                            Text("\(Int(focusedPoint.watts.rounded())) W")
                                .fontWeight(.semibold)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.quaternary.opacity(0.55), in: Capsule())
                    } else {
                        Text("Hover or click the chart to inspect a reading")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            if let historyError = viewModel.snapshot.historyError {
                Label(historyError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
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

    private var updatedText: String {
        "Updated \(viewModel.snapshot.updatedAt.formatted(date: .omitted, time: .shortened))"
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 8) {
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
            }
            Spacer()
            Button("Delete History…") {
                viewModel.showingDeleteConfirmation = true
            }
            .buttonStyle(.link)
        }
        .font(.caption)
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    private var storageText: String {
        let bytes = viewModel.snapshot.storageBytes
        guard bytes > 0 else { return "Local history is empty" }
        return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) on this Mac"
    }

    private func metric(
        title: String,
        value: String,
        detail: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.body, design: .rounded).weight(.bold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var focusedPoint: PowerPoint? {
        guard let focusedDate else { return nil }
        return plottedPoints.min {
            abs($0.date.timeIntervalSince(focusedDate)) < abs($1.date.timeIntervalSince(focusedDate))
        }
    }

    private func pointDate(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> Date? {
        let plotFrame = geometry[proxy.plotAreaFrame]
        let x = location.x - plotFrame.origin.x
        guard let date: Date = proxy.value(atX: x, as: Date.self) else { return nil }
        return plottedPoints.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }?.date
    }
}

private struct AgentInsightsView: View {
    @ObservedObject var viewModel: InsightsViewModel
    @State private var focusedIntervalID: UUID?

    private var intervals: [AgentActivityInterval] {
        AgentActivityWindow.overnight(viewModel.snapshot.activities)
    }

    private var agentNames: [String] {
        Array(Set(intervals.map(\.agentName))).sorted()
    }

    private var focusedInterval: AgentActivityInterval? {
        guard let focusedIntervalID else { return nil }
        return intervals.first { $0.id == focusedIntervalID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent activity")
                        .font(.title3.weight(.bold))
                    Text("Overnight sessions · prompts and file paths stay local")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(summaryText)
                        .font(.subheadline.weight(.semibold))
                    Text("18:00–12:00 local time")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                activityMetric(
                    title: "Active time",
                    value: activeTimeText,
                    systemImage: "clock.fill",
                    tint: .orange
                )
                activityMetric(
                    title: "Peak sessions",
                    value: peakSessionsText,
                    systemImage: "person.3.fill",
                    tint: .accentColor
                )
                Spacer()
            }

            HStack(spacing: 14) {
                legend(color: .accentColor, title: "Finished")
                legend(color: .orange, title: "Running")
                Spacer()
                Text("Hover or click a segment")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if intervals.isEmpty {
                EmptyInsightsState(
                    symbol: "terminal",
                    title: "No agent activity yet",
                    message: "Supported agents appear here when Sleep Switch sees them working."
                )
                .frame(height: 220)
            } else {
                Chart(intervals) { interval in
                    RectangleMark(
                        xStart: .value("Start", interval.startedAt),
                        xEnd: .value("End", interval.effectiveEnd),
                        y: .value("Agent", interval.agentName)
                    )
                    .foregroundStyle(interval.state == .running ? Color.orange : Color.accentColor)
                    .opacity(focusedIntervalID == nil || focusedIntervalID == interval.id ? 1 : 0.38)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                            .foregroundStyle(.secondary.opacity(0.22))
                        AxisTick()
                        AxisValueLabel()
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: agentNames) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                            .foregroundStyle(.secondary.opacity(0.16))
                        AxisValueLabel()
                    }
                }
                .chartYScale(domain: agentNames)
                .chartPlotStyle { plotArea in
                    plotArea
                        .background(Color.orange.opacity(0.025))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    focusedIntervalID = intervalID(at: location, proxy: proxy, geometry: geometry)
                                case .ended:
                                    focusedIntervalID = nil
                                }
                            }
                            .onTapGesture { location in
                                focusedIntervalID = intervalID(at: location, proxy: proxy, geometry: geometry)
                            }
                    }
                }
                .frame(height: max(210, min(310, CGFloat(agentNames.count) * 58 + 120)))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Agent activity intervals")
            }

            if let focusedInterval {
                HStack(spacing: 10) {
                    Image(systemName: focusedInterval.state == .running ? "circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(focusedInterval.state == .running ? Color.orange : Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(focusedInterval.agentName)
                            .font(.subheadline.weight(.semibold))
                        Text(intervalDetail(focusedInterval))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Clear") {
                        focusedIntervalID = nil
                    }
                    .buttonStyle(.link)
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack(alignment: .top, spacing: 8) {
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

    private var activeTimeText: String {
        let seconds = intervals.reduce(0) { $0 + $1.duration }
        let hours = Int(seconds) / 3_600
        let minutes = (Int(seconds) % 3_600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private var peakSessionsText: String {
        let peak = intervals.map(\.peakSessionCount).max() ?? 0
        return "\(peak)"
    }

    private func activityMetric(title: String, value: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.uppercased())
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.body, design: .rounded).weight(.bold))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func legend(color: Color, title: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func intervalID(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> UUID? {
        let plotFrame = geometry[proxy.plotAreaFrame]
        let x = location.x - plotFrame.origin.x
        guard let date: Date = proxy.value(atX: x, as: Date.self) else { return nil }
        let candidates = intervals.filter {
            $0.startedAt <= date && date <= $0.effectiveEnd
        }
        return candidates.sorted { $0.duration < $1.duration }.first?.id
    }

    private func intervalDetail(_ interval: AgentActivityInterval) -> String {
        let range = "\(interval.startedAt.formatted(date: .abbreviated, time: .shortened)) – \(interval.effectiveEnd.formatted(date: .omitted, time: .shortened))"
        let minutes = max(1, Int(interval.duration / 60))
        let sessions = "peak \(interval.peakSessionCount) session\(interval.peakSessionCount == 1 ? "" : "s")"
        return "\(range) · \(minutes) min · \(sessions)"
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
