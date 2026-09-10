import SwiftUI

/// The same layout is used by the Lock Screen and the in-app preview.
struct CompanionLiveActivityView: View {
    let state: CompanionLiveActivityContentState
    var isStale = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer").font(.subheadline).foregroundStyle(.blue)
                Text(state.macName).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if isStale {
                    Label("Stale", systemImage: "clock.badge.exclamationmark")
                        .font(.caption.weight(.medium)).foregroundStyle(.orange)
                } else {
                    Image(systemName: "waveform.path").foregroundStyle(.blue).accessibilityLabel("Recent readings")
                }
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(state.displayedMetrics) { metric in
                    VStack(alignment: .leading, spacing: 5) {
                        Group {
                            if typeSize > .large { Text(metric.title) }
                            else { Label(metric.title, systemImage: metric.symbol) }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        CompanionLiveMetricValue(state: state, metric: metric, isStale: isStale)
                            .font(.title3.weight(.semibold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.65)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            if isStale {
                Text("Updated \(state.updatedAt, style: .relative) ago")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            } else if state.displayedMetrics.contains(.agents), let summary = state.agentSummary {
                Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(16)
        // Live Activities have a limited system presentation height. Keep the
        // preview at the same readable size; VoiceOver still reads every metric.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

struct CompanionLiveMetricValue: View {
    let state: CompanionLiveActivityContentState
    let metric: CompanionLiveMetric
    var isStale = false
    var body: some View {
        if metric == .session, state.hasManualSession != false, let end = state.endsAt {
            if end > Date() {
                Text(timerInterval: min(state.updatedAt, end)...end, countsDown: true)
            } else { Text("Ended") }
        } else {
            Text(state.value(for: metric))
                .foregroundStyle(isStale ? .secondary : .primary)
        }
    }
}
