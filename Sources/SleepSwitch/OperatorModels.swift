import Foundation

/// Normalized, prompt-free data returned by a local harness adapter. These
/// models deliberately carry no command text, message text, tool payloads,
/// credentials, or raw source records.
enum OperatorSessionState: String, Codable, CaseIterable {
    case running
    case finished
    case aborted
    case unknown
}

/// A local-only view of the Codex desktop thread catalog. Unlike the compact
/// Operator session metrics, this intentionally includes titles and message
/// excerpts so the Mac can act as a useful mirror. It is never persisted by
/// `OperatorStore` and is never included in the iCloud companion summary.
enum CodexThreadStatus: String, Codable, CaseIterable {
    case running
    case finished
    case stopped
    case waiting
    case unknown
}

struct CodexThreadMessage: Equatable, Identifiable {
    enum Role: String, Equatable {
        case user
        case agent
    }

    let id: String
    let role: Role
    let text: String
    let createdAt: Date
}

struct CodexThreadMirror: Equatable, Identifiable {
    let id: String
    let title: String
    let preview: String
    let cwd: String
    let projectName: String?
    let sectionID: String?
    let sectionName: String?
    let sectionPosition: Int?
    let isPinned: Bool
    let isArchived: Bool
    let status: CodexThreadStatus
    let updatedAt: Date
    let startedAt: Date?
    let completedAt: Date?
    let messages: [CodexThreadMessage]

    var boardLane: String { sectionName ?? "No section" }
}

struct CodexMirrorSnapshot: Equatable {
    let isAvailable: Bool
    let threads: [CodexThreadMirror]
    let issue: String?

    static let unavailable = CodexMirrorSnapshot(
        isAvailable: false,
        threads: [],
        issue: nil
    )
}

enum OperatorMetricKind: String, Codable, CaseIterable {
    case inputTokens
    case outputTokens
    case reasoningTokens
    case cachedTokens
    case durationSeconds
}

enum OperatorEventKind: String, Codable, CaseIterable {
    case sessionStarted
    case sessionFinished
    case sessionAborted
    case skillUsed
}

enum OperatorAvailability: String, Codable, Equatable {
    case available
    case unavailable
    case permissionRequired
    case malformedSource
}

struct HarnessCapability: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case sessions
        case tokenUsage
        case skills
        case sessionHistory
    }

    let harnessID: String
    let kind: Kind
    let isSupported: Bool

    var id: String { "\(harnessID):\(kind.rawValue)" }
}

struct OperatorSession: Codable, Equatable, Identifiable {
    let id: String
    let harnessID: String
    let harnessName: String
    let state: OperatorSessionState
    let startedAt: Date
    let endedAt: Date?
    let lastActivityAt: Date?
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cachedTokens: Int

    var totalTokens: Int {
        max(0, inputTokens) + max(0, outputTokens) + max(0, reasoningTokens)
    }

    var durationSeconds: TimeInterval {
        max(0, (endedAt ?? lastActivityAt ?? Date()).timeIntervalSince(startedAt))
    }

    var metrics: [OperatorMetric] {
        [
            OperatorMetric(sessionID: id, kind: .inputTokens, value: Double(max(0, inputTokens))),
            OperatorMetric(sessionID: id, kind: .outputTokens, value: Double(max(0, outputTokens))),
            OperatorMetric(sessionID: id, kind: .reasoningTokens, value: Double(max(0, reasoningTokens))),
            OperatorMetric(sessionID: id, kind: .cachedTokens, value: Double(max(0, cachedTokens))),
            OperatorMetric(sessionID: id, kind: .durationSeconds, value: durationSeconds)
        ]
    }
}

struct OperatorMetric: Codable, Equatable, Identifiable {
    let sessionID: String
    let kind: OperatorMetricKind
    let value: Double

    var id: String { "\(sessionID):\(kind.rawValue)" }
}

struct OperatorEvent: Codable, Equatable, Identifiable {
    let id: String
    let sessionID: String
    let harnessID: String
    let kind: OperatorEventKind
    let occurredAt: Date
}

struct OperatorSkill: Codable, Equatable, Identifiable {
    /// Stable only for this Mac. It is never sent in the iCloud summary.
    let id: String
    let sourceURL: URL
    let name: String
    let sourceGroup: String
    let fingerprint: String
    let modifiedAt: Date
}

struct OperatorSkillMetadata: Codable, Equatable {
    let skillID: String
    var isFavourite: Bool
    var tags: [String]
}

struct OperatorSkillRecord: Equatable, Identifiable {
    let skill: OperatorSkill
    let metadata: OperatorSkillMetadata
    let useCount: Int

    var id: String { skill.id }
}

struct SkillUseEvent: Codable, Equatable, Identifiable {
    let id: String
    let skillID: String
    let sessionID: String?
    let harnessID: String?
    let occurredAt: Date
}

struct OperatorAdapterSnapshot: Equatable {
    let harnessID: String
    let harnessName: String
    let availability: OperatorAvailability
    let refreshedAt: Date
    let capabilities: [HarnessCapability]
    let sessions: [OperatorSession]
    let events: [OperatorEvent]
}

protocol OperatorAdapter {
    var harnessID: String { get }
    var harnessName: String { get }
    func snapshot() -> OperatorAdapterSnapshot
}

enum OperatorPrivacy {
    /// The companion summary must stay compact and cannot transfer any raw
    /// skill content, filesystem location, prompts, or event payload.
    static func compactTokenDelta(from sessions: [OperatorSession]) -> Int {
        sessions.reduce(0) { $0 + $1.totalTokens }
    }
}
