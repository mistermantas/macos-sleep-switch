import Foundation

enum CompanionRemoteAction: String, Codable, CaseIterable {
    case sleepMac
    case sleepDisplay
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
}

struct CompanionMacCapabilities: Codable, Equatable {
    var canSleepMac = true
    var canSleepDisplay = false
    var canLockMac = false
    var canRestartMac = false
    var canShutdownMac = false
    var canSetKeepAwake = false
    var supportsCloudKit = false
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
    let capabilities: CompanionMacCapabilities

    var id: String { deviceID }

    var isStale: Bool {
        Date().timeIntervalSince(lastSeen) > 5 * 60
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
        case .sleepDisplay, .sleepDisplayUntilAgentsFinish:
            capabilities.canSleepDisplay
        case .lockMac:
            capabilities.canLockMac
        case .restartMac:
            capabilities.canRestartMac
        case .shutdownMac:
            capabilities.canShutdownMac
        case .setKeepAwake:
            capabilities.canSetKeepAwake
        case .panicStop:
            true
        }
        return supported ? .success(()) : .failure(.unsupportedAction)
    }
}
