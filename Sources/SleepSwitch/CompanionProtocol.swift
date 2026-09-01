import Foundation

enum CompanionTimeText {
    static func elapsed(
        since date: Date,
        now: Date = Date()
    ) -> String {
        let totalSeconds = max(0, Int(now.timeIntervalSince(date)))
        if totalSeconds < 60 {
            return "just now"
        }

        let totalMinutes = totalSeconds / 60
        if totalMinutes < 60 {
            return "\(totalMinutes)m ago"
        }

        let totalHours = totalMinutes / 60
        let remainingMinutes = totalMinutes % 60
        if totalHours < 24 {
            return remainingMinutes == 0
                ? "\(totalHours)h ago"
                : "\(totalHours)h \(remainingMinutes)m ago"
        }

        let days = totalHours / 24
        let remainingHours = totalHours % 24
        return remainingHours == 0
            ? "\(days)d ago"
            : "\(days)d \(remainingHours)h ago"
    }
}

enum CompanionRemoteAction: String, Codable, CaseIterable {
    case sleepMac
    case sleepDisplay
    case wakeDisplay
    case wakeMac
    case lockMac
    case restartMac
    case shutdownMac
    case sleepDisplayUntilAgentsFinish
    case sleepMacWhenAgentsFinish
    case shutdownMacWhenAgentsFinish
    case setKeepAwake
    case startManualSession
    case stopManualSession
    case setCoolingProfile
    case setSafetyPreferences
    case panicStop

    var title: String {
        switch self {
        case .sleepMac:
            return "Sleep Mac"
        case .sleepDisplay:
            return "Sleep Display"
        case .wakeDisplay:
            return "Wake Display"
        case .wakeMac:
            return "Wake Mac"
        case .lockMac:
            return "Lock Mac"
        case .restartMac:
            return "Restart Mac"
        case .shutdownMac:
            return "Shut Down Mac"
        case .sleepDisplayUntilAgentsFinish:
            return "Sleep Display Until Agents Finish"
        case .sleepMacWhenAgentsFinish:
            return "Sleep Mac When Agents Finish"
        case .shutdownMacWhenAgentsFinish:
            return "Shut Down Mac When Agents Finish"
        case .setKeepAwake:
            return "Set Keep Awake"
        case .startManualSession:
            return "Start Manual Session"
        case .stopManualSession:
            return "Stop Manual Session"
        case .setCoolingProfile:
            return "Set Cooling Profile"
        case .setSafetyPreferences:
            return "Update Safety Settings"
        case .panicStop:
            return "Stop Sleep Switch"
        }
    }

    var isDestructive: Bool {
        self == .restartMac || self == .shutdownMac || self == .shutdownMacWhenAgentsFinish || self == .panicStop
    }

    var requiresConfirmation: Bool {
        switch self {
        case .sleepMac, .sleepDisplay, .restartMac, .shutdownMac, .sleepMacWhenAgentsFinish,
             .shutdownMacWhenAgentsFinish, .lockMac, .panicStop:
            return true
        case .wakeDisplay, .wakeMac, .sleepDisplayUntilAgentsFinish, .setKeepAwake,
             .startManualSession, .stopManualSession, .setCoolingProfile,
             .setSafetyPreferences:
            return false
        }
    }

    var symbolName: String {
        switch self {
        case .sleepMac:
            return "moon.zzz"
        case .sleepDisplay:
            return "display"
        case .wakeDisplay:
            return "sun.max"
        case .wakeMac:
            return "power"
        case .lockMac:
            return "lock"
        case .restartMac:
            return "arrow.clockwise"
        case .shutdownMac:
            return "power"
        case .sleepDisplayUntilAgentsFinish:
            return "moon.zzz.fill"
        case .sleepMacWhenAgentsFinish:
            return "moon.badge.clock"
        case .shutdownMacWhenAgentsFinish:
            return "power.circle"
        case .setKeepAwake:
            return "cup.and.saucer.fill"
        case .startManualSession:
            return "play.circle.fill"
        case .stopManualSession:
            return "stop.circle.fill"
        case .setCoolingProfile:
            return "fan"
        case .setSafetyPreferences:
            return "shield.checkered"
        case .panicStop:
            return "stop.circle"
        }
    }
}

enum CompanionCommandStage: String, Equatable {
    case sending
    case waitingForMac
    case confirming
    case completed
    case failed
}

struct CompanionCommandProgress: Equatable, Identifiable {
    let commandID: UUID
    let actionTitle: String
    let stage: CompanionCommandStage

    var id: UUID { commandID }

    var fraction: Double {
        switch stage {
        case .sending: 0.18
        case .waitingForMac: 0.52
        case .confirming: 0.82
        case .completed, .failed: 1
        }
    }

    var statusText: String {
        switch stage {
        case .sending: "Sending"
        case .waitingForMac: "Waiting for Mac"
        case .confirming: "Confirming"
        case .completed: "Done"
        case .failed: "Failed"
        }
    }

    var isTerminal: Bool {
        stage == .completed || stage == .failed
    }

    func withStage(_ stage: CompanionCommandStage) -> CompanionCommandProgress {
        CompanionCommandProgress(
            commandID: commandID,
            actionTitle: actionTitle,
            stage: stage
        )
    }
}

struct CompanionMacCapabilities: Codable, Equatable {
    var canSleepMac = true
    var canSleepDisplay = false
    var canWakeDisplay = true
    var canWakeMac = false
    var canLockMac = false
    var canRestartMac = false
    var canShutdownMac = false
    var canSetKeepAwake = false
    var canSleepDisplayUntilAgentsFinish = false
    /// Optional so companions can safely decode status from older Mac builds.
    var canSleepMacWhenAgentsFinish: Bool? = nil
    /// Optional so companions can safely decode status from older Mac builds.
    var canShutdownMacWhenAgentsFinish: Bool? = nil
    var supportsCloudKit = false
    var canControlManualSession: Bool? = nil
    var canSetCoolingProfile: Bool? = nil
    var canPreventSleepWithLidClosed: Bool? = nil
    var canSetSafetyPreferences: Bool? = nil

    var availableActions: [CompanionRemoteAction] {
        CompanionRemoteAction.allCases.filter { action in
            switch action {
            case .sleepMac:
                canSleepMac
            case .sleepDisplay:
                canSleepDisplay
            case .wakeDisplay:
                canWakeDisplay
            case .wakeMac:
                canWakeMac
            case .lockMac:
                canLockMac
            case .restartMac:
                canRestartMac
            case .shutdownMac:
                canShutdownMac
            case .sleepDisplayUntilAgentsFinish:
                canSleepDisplayUntilAgentsFinish
            case .sleepMacWhenAgentsFinish:
                canSleepMacWhenAgentsFinish == true
            case .shutdownMacWhenAgentsFinish:
                canShutdownMacWhenAgentsFinish == true
            case .setKeepAwake:
                canSetKeepAwake
            case .startManualSession, .stopManualSession:
                canControlManualSession == true
            case .setCoolingProfile:
                canSetCoolingProfile == true
            case .setSafetyPreferences:
                canSetSafetyPreferences == true
            case .panicStop:
                true
            }
        }
    }
}

struct CompanionAgentStatus: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let sessionCount: Int
}

struct CompanionManualSessionStatus: Codable, Equatable {
    let startedAt: Date
    let endsAt: Date?

    var isActive: Bool { endsAt.map { $0 > Date() } ?? true }
}

struct CompanionSafetySettings: Codable, Equatable {
    let lidClosedMinimumBatteryPercent: Int
    let lidClosedRequiresExternalPower: Bool
    let lidClosedAllowedNow: Bool
    let lidClosedBlockReason: String?
}

struct CompanionFanStatus: Codable, Equatable, Identifiable {
    let id: Int
    let actualRPM: Double
    let targetRPM: Double?
    let maximumRPM: Double?
}

enum CompanionTemperatureGroup: String, Codable, CaseIterable {
    case cpu
    case gpu
    case auxiliary

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .auxiliary: "Memory & system"
        }
    }
}

struct CompanionTemperatureSensor: Codable, Equatable, Identifiable {
    let key: String
    let group: CompanionTemperatureGroup
    let celsius: Double

    var id: String { "\(group.rawValue)-\(key)" }
}

enum CompanionTemperatureParser {
    static func sensors(from diagnosticMetadata: String?) -> [CompanionTemperatureSensor] {
        guard let diagnosticMetadata else { return [] }
        let groupPrefixes: [(String, CompanionTemperatureGroup)] = [
            ("cpu-sensors=", .cpu),
            ("gpu-sensors=", .gpu),
            ("auxiliary-sensors=", .auxiliary)
        ]
        return diagnosticMetadata
            .split(whereSeparator: \.isNewline)
            .flatMap { line -> [CompanionTemperatureSensor] in
                let text = String(line)
                guard let match = groupPrefixes.first(where: { text.hasPrefix($0.0) }) else {
                    return []
                }
                return text.dropFirst(match.0.count)
                    .split(separator: ",")
                    .compactMap { reading in
                        let components = reading.split(separator: "=", maxSplits: 1)
                        guard components.count == 2,
                              let value = Double(components[1]),
                              value.isFinite,
                              (10...120).contains(value) else {
                            return nil
                        }
                        return CompanionTemperatureSensor(
                            key: String(components[0]),
                            group: match.1,
                            celsius: value
                        )
                    }
            }
            .sorted {
                if $0.group.rawValue != $1.group.rawValue {
                    return $0.group.rawValue < $1.group.rawValue
                }
                return $0.key.localizedStandardCompare($1.key) == .orderedAscending
            }
    }
}

struct CompanionCoolingStatus: Codable, Equatable {
    let profile: String
    let state: String
    let temperatureCelsius: Double?
    let verifiedDemand: Double?
    let fans: [CompanionFanStatus]
    let message: String?
    let availableProfiles: [String]?
    var sensors: [CompanionTemperatureSensor]? = nil
}

struct CompanionMacStatus: Codable, Equatable, Identifiable {
    let deviceID: String
    let displayName: String
    let build: String
    let lastSeen: Date
    let uptimeSeconds: TimeInterval
    let powerSource: EnergySource
    let batteryPercent: Double?
    let thermalState: String
    let activeAgentCount: Int
    let activeSessionCount: Int
    let awakeMode: String
    let displayAsleep: Bool
    let isKeepingAwake: Bool
    let keepDisplayAwake: Bool
    let automaticAgentAwakeEnabled: Bool
    let wakeDisplayWhenAgentsFinish: Bool
    let estimatedWatts: Double?
    let energySource: EnergySource
    let energyConfidence: EnergyConfidence
    let isCharging: Bool
    let chargingWatts: Double?
    let capabilities: CompanionMacCapabilities
    let agents: [CompanionAgentStatus]?
    let manualSession: CompanionManualSessionStatus?
    let cooling: CompanionCoolingStatus?
    var safety: CompanionSafetySettings? = nil

    init(
        deviceID: String,
        displayName: String,
        build: String,
        lastSeen: Date,
        uptimeSeconds: TimeInterval,
        powerSource: EnergySource,
        batteryPercent: Double?,
        thermalState: String,
        activeAgentCount: Int,
        activeSessionCount: Int,
        awakeMode: String,
        displayAsleep: Bool,
        isKeepingAwake: Bool,
        keepDisplayAwake: Bool,
        automaticAgentAwakeEnabled: Bool,
        wakeDisplayWhenAgentsFinish: Bool,
        estimatedWatts: Double?,
        energySource: EnergySource,
        energyConfidence: EnergyConfidence,
        isCharging: Bool,
        chargingWatts: Double? = nil,
        capabilities: CompanionMacCapabilities,
        agents: [CompanionAgentStatus]? = nil,
        manualSession: CompanionManualSessionStatus? = nil,
        cooling: CompanionCoolingStatus? = nil,
        safety: CompanionSafetySettings? = nil
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.build = build
        self.lastSeen = lastSeen
        self.uptimeSeconds = uptimeSeconds
        self.powerSource = powerSource
        self.batteryPercent = batteryPercent
        self.thermalState = thermalState
        self.activeAgentCount = activeAgentCount
        self.activeSessionCount = activeSessionCount
        self.awakeMode = awakeMode
        self.displayAsleep = displayAsleep
        self.isKeepingAwake = isKeepingAwake
        self.keepDisplayAwake = keepDisplayAwake
        self.automaticAgentAwakeEnabled = automaticAgentAwakeEnabled
        self.wakeDisplayWhenAgentsFinish = wakeDisplayWhenAgentsFinish
        self.estimatedWatts = estimatedWatts
        self.energySource = energySource
        self.energyConfidence = energyConfidence
        self.isCharging = isCharging
        self.chargingWatts = chargingWatts
        self.capabilities = capabilities
        self.agents = agents
        self.manualSession = manualSession
        self.cooling = cooling
        self.safety = safety
    }

    var id: String { deviceID }

    static let unavailable = CompanionMacStatus(
        deviceID: "unavailable",
        displayName: "This Mac",
        build: "Unknown",
        lastSeen: .distantPast,
        uptimeSeconds: 0,
        powerSource: .unavailable,
        batteryPercent: nil,
        thermalState: "unknown",
        activeAgentCount: 0,
        activeSessionCount: 0,
        awakeMode: "unknown",
        displayAsleep: false,
        isKeepingAwake: false,
        keepDisplayAwake: false,
        automaticAgentAwakeEnabled: false,
        wakeDisplayWhenAgentsFinish: false,
        estimatedWatts: nil,
        energySource: .unavailable,
        energyConfidence: .unavailable,
        isCharging: false,
        capabilities: CompanionMacCapabilities(supportsCloudKit: false)
    )

    var isStale: Bool {
        isStale(at: Date())
    }

    func isStale(at date: Date) -> Bool {
        date.timeIntervalSince(lastSeen) > 5 * 60
    }

    func refreshingLastSeen(at date: Date = Date()) -> CompanionMacStatus {
        CompanionMacStatus(
            deviceID: deviceID,
            displayName: displayName,
            build: build,
            lastSeen: date,
            uptimeSeconds: uptimeSeconds,
            powerSource: powerSource,
            batteryPercent: batteryPercent,
            thermalState: thermalState,
            activeAgentCount: activeAgentCount,
            activeSessionCount: activeSessionCount,
            awakeMode: awakeMode,
            displayAsleep: displayAsleep,
            isKeepingAwake: isKeepingAwake,
            keepDisplayAwake: keepDisplayAwake,
            automaticAgentAwakeEnabled: automaticAgentAwakeEnabled,
            wakeDisplayWhenAgentsFinish: wakeDisplayWhenAgentsFinish,
            estimatedWatts: estimatedWatts,
            energySource: energySource,
            energyConfidence: energyConfidence,
            isCharging: isCharging,
            chargingWatts: chargingWatts,
            capabilities: capabilities,
            agents: agents,
            manualSession: manualSession,
            cooling: cooling,
            safety: safety
        )
    }

    /// Returns a local projection of a keep-awake command. The companion uses
    /// this while CloudKit is carrying the command to the Mac so controls do
    /// not snap back to their stale server value.
    func applyingKeepAwake(parameters: [String: String]) -> CompanionMacStatus {
        CompanionMacStatus(
            deviceID: deviceID,
            displayName: displayName,
            build: build,
            lastSeen: lastSeen,
            uptimeSeconds: uptimeSeconds,
            powerSource: powerSource,
            batteryPercent: batteryPercent,
            thermalState: thermalState,
            activeAgentCount: activeAgentCount,
            activeSessionCount: activeSessionCount,
            awakeMode: parameters["awakeMode"] ?? awakeMode,
            displayAsleep: displayAsleep,
            isKeepingAwake: isKeepingAwake,
            keepDisplayAwake: parameters["keepDisplayAwake"].flatMap(Bool.init)
                ?? keepDisplayAwake,
            automaticAgentAwakeEnabled: parameters["enabled"].flatMap(Bool.init)
                ?? automaticAgentAwakeEnabled,
            wakeDisplayWhenAgentsFinish: parameters["wakeWhenAgentsFinish"].flatMap(Bool.init)
                ?? wakeDisplayWhenAgentsFinish,
            estimatedWatts: estimatedWatts,
            energySource: energySource,
            energyConfidence: energyConfidence,
            isCharging: isCharging,
            chargingWatts: chargingWatts,
            capabilities: capabilities,
            agents: agents,
            manualSession: manualSession,
            cooling: cooling,
            safety: safety
        )
    }
}

enum CompanionMacSelection {
    static func preferred(
        from macs: [CompanionMacStatus],
        persistedDeviceID: String,
        now: Date = Date()
    ) -> CompanionMacStatus? {
        let persisted = macs.first { $0.deviceID == persistedDeviceID }
        if let persisted, !persisted.isStale(at: now) {
            return persisted
        }

        if let persisted {
            if let replacement = macs
                .filter({
                    $0.deviceID != persisted.deviceID
                        && $0.displayName == persisted.displayName
                        && !$0.isStale(at: now)
                })
                .max(by: { $0.lastSeen < $1.lastSeen }) {
                return replacement
            }
            return persisted
        }

        return macs
            .filter({ !$0.isStale(at: now) })
            .max(by: { $0.lastSeen < $1.lastSeen })
            ?? macs.max(by: { $0.lastSeen < $1.lastSeen })
    }
}

struct CompanionRemoteCommand: Codable, Equatable, Identifiable {
    let id: UUID
    let targetDeviceID: String
    let action: CompanionRemoteAction
    let parameters: [String: String]
    let requesterDeviceID: String
    let nonce: String
    let createdAt: Date
    let expiresAt: Date
    let policyVersion: Int

    var isExpired: Bool { Date() >= expiresAt }
}

struct CompanionRemoteResult: Codable, Equatable {
    let commandID: UUID
    let accepted: Bool
    let executed: Bool
    let completedAt: Date
    let message: String?
}

enum CompanionCommandValidationError: Error, Equatable {
    case wrongDevice
    case expired
    case unsupportedAction
    case replay
}

struct CompanionCommandPolicy {
    static func validate(
        _ command: CompanionRemoteCommand,
        targetDeviceID: String,
        capabilities: CompanionMacCapabilities,
        now: Date = Date(),
        seenNonces: Set<String> = []
    ) -> Result<Void, CompanionCommandValidationError> {
        guard command.targetDeviceID == targetDeviceID else {
            return .failure(.wrongDevice)
        }
        guard command.expiresAt > now, command.createdAt <= now else {
            return .failure(.expired)
        }
        guard !seenNonces.contains(command.nonce) else {
            return .failure(.replay)
        }

        let supported: Bool = switch command.action {
        case .sleepMac:
            capabilities.canSleepMac
        case .sleepDisplay:
            capabilities.canSleepDisplay
        case .wakeDisplay:
            capabilities.canWakeDisplay
        case .wakeMac:
            capabilities.canWakeMac
        case .lockMac:
            capabilities.canLockMac
        case .restartMac:
            capabilities.canRestartMac
        case .shutdownMac:
            capabilities.canShutdownMac
        case .setKeepAwake:
            capabilities.canSetKeepAwake
        case .startManualSession, .stopManualSession:
            capabilities.canControlManualSession == true
        case .setCoolingProfile:
            capabilities.canSetCoolingProfile == true
        case .setSafetyPreferences:
            capabilities.canSetSafetyPreferences == true
        case .sleepDisplayUntilAgentsFinish:
            capabilities.canSleepDisplayUntilAgentsFinish
        case .sleepMacWhenAgentsFinish:
            capabilities.canSleepMacWhenAgentsFinish == true
        case .shutdownMacWhenAgentsFinish:
            capabilities.canShutdownMacWhenAgentsFinish == true
        case .panicStop:
            true
        }
        return supported ? .success(()) : .failure(.unsupportedAction)
    }
}
