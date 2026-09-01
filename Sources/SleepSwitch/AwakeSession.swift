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
        wakeWhenAgentsFinishArmed: Bool,
        detectedAgents: [DetectedAgent],
        agentIdleGraceActive: Bool = false
    ) -> Bool {
        manualSession != nil
            || (automaticAgentAwakeEnabled && !detectedAgents.isEmpty)
            || (automaticAgentAwakeEnabled && agentIdleGraceActive)
            || wakeWhenAgentsFinishArmed
    }
}

/// The direct build can temporarily suppress normal lid sleep. Keep that
/// privilege behind a small, deterministic policy so the decision is the same
/// in the menu, settings window, and companion status.
enum LidClosedSafetyPolicy {
    static let defaultMinimumBatteryPercent = 11

    enum Decision: Equatable {
        case allowed
        case blockedLowBattery(percent: Int)
        case blockedOnBattery

        var message: String? {
            switch self {
            case .allowed:
                return nil
            case .blockedLowBattery(let percent):
                return "Lid-closed mode paused at \(percent)% battery"
            case .blockedOnBattery:
                return "Lid-closed mode waits for external power"
            }
        }
    }

    static func decision(
        batteryPercent: Double?,
        isOnExternalPower: Bool,
        minimumBatteryPercent: Int,
        requiresExternalPower: Bool
    ) -> Decision {
        let floor = min(max(minimumBatteryPercent, 1), 100)
        if let batteryPercent, batteryPercent.isFinite,
           Int(batteryPercent.rounded(.down)) <= floor {
            return .blockedLowBattery(percent: Int(batteryPercent.rounded(.down)))
        }
        if requiresExternalPower && !isOnExternalPower {
            return .blockedOnBattery
        }
        return .allowed
    }
}

struct AgentTriggerConfiguration: Codable, Equatable {
    var isEnabled: Bool
    var whenAgentsStartCommand: String
    var whenAgentsFinishCommand: String

    static let disabled = AgentTriggerConfiguration(
        isEnabled: false,
        whenAgentsStartCommand: "",
        whenAgentsFinishCommand: ""
    )
}

enum AgentIdleGracePolicy {
    static let duration: TimeInterval = 5 * 60

    static func deadline(
        previousAgentCount: Int,
        currentAgentCount: Int,
        automaticAgentAwakeEnabled: Bool,
        hasManualSession: Bool,
        now: Date = Date()
    ) -> Date? {
        guard automaticAgentAwakeEnabled,
              !hasManualSession,
              previousAgentCount > 0,
              currentAgentCount == 0 else {
            return nil
        }
        return now.addingTimeInterval(duration)
    }

    static func isActive(deadline: Date?, now: Date = Date()) -> Bool {
        deadline.map { $0 > now } ?? false
    }

    static func remainingUserIdleDelay(userIdleSeconds: TimeInterval) -> TimeInterval {
        max(0, duration - max(0, userIdleSeconds))
    }
}

enum DisplayWakePolicy {
    static func shouldAttemptWake(
        isArmed: Bool,
        detectedAgents: [DetectedAgent]
    ) -> Bool {
        isArmed && detectedAgents.isEmpty
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
