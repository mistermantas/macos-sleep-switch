import Foundation

struct AwakeSession: Equatable {
    static let maximumDurationSeconds = (23 * 60 * 60) + (59 * 60)

    let startedAt: Date
    let durationSeconds: Int?

    var endDate: Date? {
        guard let durationSeconds else { return nil }
        return startedAt.addingTimeInterval(TimeInterval(durationSeconds))
    }

    func remainingSeconds(at date: Date = Date()) -> Int? {
        guard let endDate else { return nil }
        return max(0, Int(ceil(endDate.timeIntervalSince(date))))
    }

    func hasExpired(at date: Date = Date()) -> Bool {
        guard let remainingSeconds = remainingSeconds(at: date) else {
            return false
        }
        return remainingSeconds == 0
    }
}

enum AwakePolicy {
    static func shouldKeepAwake(
        manualSession: AwakeSession?,
        automaticAgentAwakeEnabled: Bool,
        detectedAgents: [DetectedAgent]
    ) -> Bool {
        manualSession != nil
            || (automaticAgentAwakeEnabled && !detectedAgents.isEmpty)
    }
}

enum AwakeTimeText {
    static let presetSeconds = [
        5 * 60,
        15 * 60,
        30 * 60,
        60 * 60,
        2 * 60 * 60,
        4 * 60 * 60
    ]

    static func duration(seconds: Int?) -> String {
        guard let seconds else { return "Indefinitely" }

        let totalMinutes = seconds / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours == 0 {
            return "\(minutes) \(minutes == 1 ? "Minute" : "Minutes")"
        }

        if minutes == 0 {
            return "\(hours) \(hours == 1 ? "Hour" : "Hours")"
        }

        return "\(hours)h \(minutes)m"
    }

    static func remaining(seconds: Int) -> String {
        if seconds < 60 {
            return "less than a minute left"
        }

        let roundedMinutes = Int(ceil(Double(seconds) / 60))
        let hours = roundedMinutes / 60
        let minutes = roundedMinutes % 60

        if hours == 0 {
            return "\(roundedMinutes)m left"
        }

        if minutes == 0 {
            return "\(hours)h left"
        }

        return "\(hours)h \(minutes)m left"
    }
}
