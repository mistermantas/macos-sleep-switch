import Foundation

/// Bounded metadata published to the user's private iCloud database. Text
/// content is fetched separately, only after sharing is enabled on the Mac.
struct CompanionOperatorSnapshot: Codable, Equatable {
    let updatedAt: Date
    var sharingEnabled: Bool
    var sessions: [CompanionOperatorSession]
    var threads: [CompanionOperatorThread]
    var skills: [CompanionOperatorSkill]
    let sources: [CompanionOperatorSource]
    let totalSessionCount: Int
    let totalThreadCount: Int
    let totalSkillCount: Int
    var triggersEnabled: Bool
    var diagnosticsEnabled: Bool
    var historyEnabled: Bool
}

struct CompanionOperatorSession: Codable, Equatable, Identifiable {
    let id: String
    let harnessID: String
    let harnessName: String
    let state: CompanionWorkState
    let startedAt: Date
    let updatedAt: Date
    let durationSeconds: TimeInterval
    let inputTokens: Int
    let outputTokens: Int
    let reasoningTokens: Int
    let cachedTokens: Int
    let title: String?
    let projectName: String?
    let threadID: String?
    var totalTokens: Int { inputTokens + outputTokens + reasoningTokens }
}

struct CompanionOperatorThread: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let projectName: String?
    var sectionID: String?
    var sectionName: String?
    var workflowLane: String
    let isPinned: Bool
    let isArchived: Bool
    let state: CompanionWorkState
    let updatedAt: Date
    let activity: CompanionWorkActivity?
    var folderID: String? = nil
    var folderName: String? = nil
}

struct CompanionOperatorSkill: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let sourceGroup: String
    var tags: [String]
    var isFavourite: Bool
    var useCount: Int
    let modifiedAt: Date
}

struct CompanionOperatorSource: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let status: String
    let capabilities: [String]
}

struct CompanionOperatorMessage: Codable, Equatable, Identifiable {
    let id: String
    let role: String
    var text: String
    let createdAt: Date
}

struct CompanionOperatorContent: Codable, Equatable {
    let itemID: String
    let kind: String
    let title: String
    var text: String?
    var messages: [CompanionOperatorMessage]
    var isTruncated: Bool

    func bounded(maximumBytes: Int = 220_000) -> CompanionOperatorContent {
        var content = self
        while (try? CompanionJSON.encoder.encode(content).count) ?? Int.max > maximumBytes {
            content.isTruncated = true
            if content.messages.count > 1 { content.messages.removeFirst() }
            else if let text = content.text, text.count > 1 { content.text = String(text.prefix(text.count / 2)) }
            else if let message = content.messages.first, message.text.count > 1 { content.messages[0].text = String(message.text.prefix(message.text.count / 2)) }
            else { break }
        }
        return content
    }
}

enum CompanionOperatorFormatting {
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return String(max(0, count))
    }

    static func duration(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value))
        if seconds >= 86_400 { return "\(seconds / 86_400)d \(seconds % 86_400 / 3_600)h" }
        if seconds >= 3_600 { return "\(seconds / 3_600)h \(seconds % 3_600 / 60)m" }
        return "\(seconds / 60)m"
    }
}
