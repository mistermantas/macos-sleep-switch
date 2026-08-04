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
}
