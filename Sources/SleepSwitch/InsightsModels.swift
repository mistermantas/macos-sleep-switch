import Foundation

enum EnergySource: String, Codable, CaseIterable {
    case battery
    case ac
    case ups
    case unavailable

    var title: String {
        switch self {
        case .battery:
            return "Battery"
        case .ac:
            return "AC power"
        case .ups:
            return "UPS"
        case .unavailable:
            return "Unavailable"
        }
    }
}

enum EnergyConfidence: String, Codable, CaseIterable {
    case measured
    case estimated
    case unavailable

    var title: String {
        switch self {
        case .measured:
            return "Measured"
        case .estimated:
            return "Estimated"
        case .unavailable:
            return "Unavailable"
        }
    }
}

struct EnergyReading: Equatable, Codable {
    let recordedAt: Date
    let watts: Double?
    let source: EnergySource
    let confidence: EnergyConfidence
    let batteryPercent: Double?
    let isCharging: Bool
    let chargingWatts: Double?

    init(
        recordedAt: Date,
        watts: Double?,
        source: EnergySource,
        confidence: EnergyConfidence,
        batteryPercent: Double?,
        isCharging: Bool,
        chargingWatts: Double? = nil
    ) {
        self.recordedAt = recordedAt
        self.watts = watts
        self.source = source
        self.confidence = confidence
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.chargingWatts = chargingWatts
    }

    var displayWatts: String {
        guard let watts, watts.isFinite else { return "—" }
        return "\(Int(watts.rounded())) W"
    }
}

struct EnergyBucket: Equatable, Codable, Identifiable {
    let bucketStart: Date
    let durationSeconds: Int
    let averageWatts: Double?
    let peakWatts: Double?
    let kilowattHours: Double?
    let source: EnergySource
    let confidence: EnergyConfidence
    let sampleCount: Int

    var id: Date { bucketStart }
    var coverage: Double { min(1, Double(sampleCount) / 5.0) }
}

enum AgentActivityState: String, Codable {
    case running
    case finished
    case unknown
}

struct AgentActivityInterval: Equatable, Codable, Identifiable {
    let id: UUID
    let agentID: String
    let agentName: String
    let startedAt: Date
    let endedAt: Date?
    let state: AgentActivityState
    let peakSessionCount: Int

    var effectiveEnd: Date { endedAt ?? Date() }

    var duration: TimeInterval {
        max(0, effectiveEnd.timeIntervalSince(startedAt))
    }
}

enum AgentActivityWindow {
    /// Returns intervals that overlap the local 18:00–12:00 overnight window.
    /// The interval itself is left intact so a session crossing noon remains honest.
    static func overnight(
        _ intervals: [AgentActivityInterval],
        calendar: Calendar = .current
    ) -> [AgentActivityInterval] {
        intervals.filter { interval in
            let intervalEnd = interval.effectiveEnd
            let day = calendar.startOfDay(for: interval.startedAt)
            for offset in -1...1 {
                guard let candidateDay = calendar.date(byAdding: .day, value: offset, to: day),
                      let windowStart = calendar.date(
                          bySettingHour: 18,
                          minute: 0,
                          second: 0,
                          of: candidateDay
                      ),
                      let windowEndDay = calendar.date(byAdding: .day, value: 1, to: candidateDay),
                      let windowEnd = calendar.date(
                          bySettingHour: 12,
                          minute: 0,
                          second: 0,
                          of: windowEndDay
                      ) else {
                    continue
                }
                if interval.startedAt < windowEnd && intervalEnd > windowStart {
                    return true
                }
            }
            return false
        }
    }
}

struct AgentActivitySummary: Equatable, Identifiable {
    let agentID: String
    let agentName: String
    let intervals: [AgentActivityInterval]

    var id: String { agentID }
}

/// A deliberately coarse day-level summary used by the iOS companion. The
/// companion never receives prompts, process names, or raw one-minute samples.
struct CompanionEnergyDay: Codable, Equatable, Identifiable {
    let dayStart: Date
    let kilowattHours: Double
    let averageWatts: Double?
    let peakWatts: Double?
    let sampleCount: Int

    var id: Date { dayStart }
}

struct CompanionAgentDay: Codable, Equatable, Identifiable {
    let dayStart: Date
    let activeSeconds: TimeInterval
    let peakSessionCount: Int
    let agentCount: Int

    var id: Date { dayStart }
}

struct CompanionHistorySnapshot: Codable, Equatable {
    let deviceID: String
    let updatedAt: Date
    let historyEnabled: Bool
    let energyBuckets: [EnergyBucket]
    let energyDays: [CompanionEnergyDay]
    let agentDays: [CompanionAgentDay]
    let storageBytes: Int64

    static func empty(deviceID: String, updatedAt: Date = Date()) -> CompanionHistorySnapshot {
        CompanionHistorySnapshot(
            deviceID: deviceID,
            updatedAt: updatedAt,
            historyEnabled: false,
            energyBuckets: [],
            energyDays: [],
            agentDays: [],
            storageBytes: 0
        )
    }
}

enum CompanionHistoryBuilder {
    static func make(
        deviceID: String,
        snapshot: InsightsSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> CompanionHistorySnapshot {
        guard snapshot.historyEnabled else {
            return .empty(deviceID: deviceID, updatedAt: now)
        }

        let buckets = snapshot.buckets
            .filter { $0.bucketStart <= now }
            .sorted { $0.bucketStart < $1.bucketStart }
        let energyDays = Dictionary(grouping: buckets) {
            calendar.startOfDay(for: $0.bucketStart)
        }
        .map { dayStart, values in
            let validValues = values.compactMap(\.averageWatts)
                .filter { $0.isFinite && $0 >= 0 }
            let totalEnergy = values.compactMap(\.kilowattHours)
                .filter { $0.isFinite && $0 >= 0 }
                .reduce(0, +)
            return CompanionEnergyDay(
                dayStart: dayStart,
                kilowattHours: totalEnergy,
                averageWatts: validValues.isEmpty
                    ? nil
                    : validValues.reduce(0, +) / Double(validValues.count),
                peakWatts: values.compactMap(\.peakWatts).max(),
                sampleCount: values.reduce(0) { $0 + $1.sampleCount }
            )
        }
        .sorted { $0.dayStart < $1.dayStart }

        let agentDays = makeAgentDays(
            intervals: snapshot.activities,
            now: now,
            calendar: calendar
        )

        // Five-minute buckets are useful for the last day, while day-level
        // summaries cover the full 30-day local retention window. Keeping at
        // most 24 hours here keeps each CloudKit payload small and predictable.
        let recentCutoff = now.addingTimeInterval(-24 * 60 * 60)
        let recentBuckets = buckets.filter { $0.bucketStart >= recentCutoff }

        return CompanionHistorySnapshot(
            deviceID: deviceID,
            updatedAt: now,
            historyEnabled: true,
            energyBuckets: recentBuckets,
            energyDays: energyDays,
            agentDays: agentDays,
            storageBytes: snapshot.storageBytes
        )
    }

    private static func makeAgentDays(
        intervals: [AgentActivityInterval],
        now: Date,
        calendar: Calendar
    ) -> [CompanionAgentDay] {
        var totals: [Date: (seconds: TimeInterval, peak: Int, agents: Set<String>)] = [:]
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)

        for interval in intervals {
            let start = max(interval.startedAt, cutoff)
            let end = min(interval.effectiveEnd, now)
            guard end > start else { continue }

            var dayStart = calendar.startOfDay(for: start)
            while dayStart < end {
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                    break
                }
                let overlapStart = max(start, dayStart)
                let overlapEnd = min(end, nextDay)
                if overlapEnd > overlapStart {
                    var total = totals[dayStart] ?? (0, 0, [])
                    total.seconds += overlapEnd.timeIntervalSince(overlapStart)
                    total.peak = max(total.peak, interval.peakSessionCount)
                    total.agents.insert(interval.agentID)
                    totals[dayStart] = total
                }
                dayStart = nextDay
            }
        }

        return totals.map { dayStart, value in
            CompanionAgentDay(
                dayStart: dayStart,
                activeSeconds: value.seconds,
                peakSessionCount: value.peak,
                agentCount: value.agents.count
            )
        }
        .sorted { $0.dayStart < $1.dayStart }
    }
}

enum InsightsRange: String, CaseIterable, Identifiable {
    case live
    case day
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .live:
            return "Live"
        case .day:
            return "24 hours"
        case .week:
            return "7 days"
        case .month:
            return "30 days"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .live:
            return 24 * 60 * 60
        case .day:
            return 24 * 60 * 60
        case .week:
            return 7 * 24 * 60 * 60
        case .month:
            return 30 * 24 * 60 * 60
        }
    }
}

struct InsightsSnapshot: Equatable {
    let energy: [EnergyReading]
    let buckets: [EnergyBucket]
    let activities: [AgentActivityInterval]
    let updatedAt: Date
    let historyEnabled: Bool
    let storageBytes: Int64
    let historyError: String?

    init(
        energy: [EnergyReading],
        buckets: [EnergyBucket],
        activities: [AgentActivityInterval],
        updatedAt: Date,
        historyEnabled: Bool,
        storageBytes: Int64,
        historyError: String? = nil
    ) {
        self.energy = energy
        self.buckets = buckets
        self.activities = activities
        self.updatedAt = updatedAt
        self.historyEnabled = historyEnabled
        self.storageBytes = storageBytes
        self.historyError = historyError
    }
}
