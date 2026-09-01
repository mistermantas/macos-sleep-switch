import Foundation

enum SleepSwitchPreferenceKey {
    static let keepDisplayAwake = "keepDisplayAwake"
    static let activateOnLaunch = "activateOnLaunch"
    static let defaultDurationSeconds = "defaultDurationSeconds"
    static let automaticAgentAwake = "automaticAgentAwake"
    static let awakeMode = "awakeMode"
    static let lidClosedMinimumBatteryPercent = "lidClosedMinimumBatteryPercent"
    static let lidClosedRequiresExternalPower = "lidClosedRequiresExternalPower"
    static let agentTriggerEnabled = "agentTriggerEnabled"
    static let agentStartedTriggerCommand = "agentStartedTriggerCommand"
    static let agentFinishedTriggerCommand = "agentFinishedTriggerCommand"
    static let agentDiagnosticsEnabled = "agentDiagnosticsEnabled"
    static let codexActiveWindowSeconds = "codexActiveWindowSeconds"
}

struct LidClosedSafetyConfiguration: Equatable {
    var minimumBatteryPercent: Int
    var requiresExternalPower: Bool

    init(defaults: UserDefaults = .standard) {
        minimumBatteryPercent = min(
            max(defaults.integer(forKey: SleepSwitchPreferenceKey.lidClosedMinimumBatteryPercent), 1),
            100
        )
        requiresExternalPower = defaults.bool(
            forKey: SleepSwitchPreferenceKey.lidClosedRequiresExternalPower
        )
    }

    func decision(for reading: EnergyReading) -> LidClosedSafetyPolicy.Decision {
        LidClosedSafetyPolicy.decision(
            batteryPercent: reading.batteryPercent,
            isOnExternalPower: reading.source == .ac || reading.isCharging,
            minimumBatteryPercent: minimumBatteryPercent,
            requiresExternalPower: requiresExternalPower
        )
    }
}

/// User-authored triggers are deliberately opt-in and run only on a real
/// transition between zero and non-zero local agent sessions. They receive no
/// prompts, source code, paths, or command lines; only event metadata.
final class AgentTriggerRunner {
    private let queue = DispatchQueue(
        label: "lt.mantas.sleepswitch.agent-trigger",
        qos: .utility
    )

    func run(
        event: Event,
        agents: [DetectedAgent],
        configuration: AgentTriggerConfiguration
    ) {
        guard configuration.isEnabled else { return }
        let command = switch event {
        case .started: configuration.whenAgentsStartCommand
        case .finished: configuration.whenAgentsFinishCommand
        }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let names = agents.map { $0.definition.name }.joined(separator: ",")
        let count = agents.reduce(0) { $0 + $1.processCount }
        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", trimmed]
            var environment = ProcessInfo.processInfo.environment
            environment["SLEEP_SWITCH_EVENT"] = event.rawValue
            environment["SLEEP_SWITCH_AGENTS"] = names
            environment["SLEEP_SWITCH_SESSION_COUNT"] = String(count)
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }

    enum Event: String {
        case started = "agents_started"
        case finished = "agents_finished"
    }
}
