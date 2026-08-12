import Foundation

enum CompanionRemoteAction: String, Codable, CaseIterable {
    case sleepMac
    case sleepDisplay
    case wakeDisplay
    case wakeMac
    case lockMac
    case restartMac
    case shutdownMac
    case sleepDisplayUntilAgentsFinish
    case setKeepAwake
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
        case .setKeepAwake:
            return "Set Keep Awake"
        case .panicStop:
            return "Stop Sleep Switch Controls"
        }
    }

    var isDestructive: Bool {
        self == .restartMac || self == .shutdownMac
    }

    var requiresConfirmation: Bool {
        switch self {
        case .sleepMac, .sleepDisplay, .restartMac, .shutdownMac, .lockMac:
            return true
        case .wakeDisplay, .wakeMac, .sleepDisplayUntilAgentsFinish, .setKeepAwake, .panicStop:
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
        case .setKeepAwake:
            return "cup.and.saucer.fill"
        case .panicStop:
            return "stop.circle"
        }
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
    var supportsCloudKit = false

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
            case .setKeepAwake:
                canSetKeepAwake
            case .panicStop:
                true
            }
        }
    }
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
    let capabilities: CompanionMacCapabilities

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
        Date().timeIntervalSince(lastSeen) > 5 * 60
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
            capabilities: capabilities
        )
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
        case .sleepDisplayUntilAgentsFinish:
            capabilities.canSleepDisplayUntilAgentsFinish
        case .panicStop:
            true
        }
        return supported ? .success(()) : .failure(.unsupportedAction)
    }
}
