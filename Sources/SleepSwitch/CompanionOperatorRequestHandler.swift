import Foundation

enum CompanionOperatorRequestError: Error, LocalizedError {
    case unavailable(String)
    var errorDescription: String? { switch self { case .unavailable(let message): message } }
}

struct CompanionOperatorRequestHandler {
    let coordinator: OperatorCoordinator
    let threads: () -> [CodexThreadMirror]
    let defaults: UserDefaults
    let refresh: () -> Void
    let setPreference: (String, Bool) throws -> Void
    let didChange: () -> Void

    func handle(_ parameters: [String: String]) throws -> CompanionOperatorContent? {
        let operation = parameters["operation"] ?? ""
        if operation == "sharing", let enabled = parameters["enabled"].flatMap(Bool.init) {
            defaults.set(enabled, forKey: CompanionOperatorProjection.sharingKey)
            return nil
        }
        if operation == "refresh" {
            refresh()
            return nil
        }
        if operation == "preferences", let enabled = parameters["enabled"].flatMap(Bool.init) {
            guard let key = parameters["key"], ["history", "diagnostics", "triggers"].contains(key) else {
                throw CompanionOperatorRequestError.unavailable("Unknown Operator setting.")
            }
            try setPreference(key, enabled)
            return nil
        }
        guard defaults.bool(forKey: CompanionOperatorProjection.sharingKey) else {
            throw CompanionOperatorRequestError.unavailable("Enable chats and skills in Operator’s sharing settings first.")
        }
        let itemID = parameters["itemID"] ?? ""
        let threads = self.threads()
        if let thread = threads.first(where: { CompanionOperatorProjection.key("thread", $0.id) == itemID }) {
            switch operation {
            case "readThread": return CompanionOperatorProjection.threadContent(thread)
            case "workflow":
                guard let lane = parameters["lane"], CompanionOperatorProjection.workflowLanes.contains(lane) else {
                    throw CompanionOperatorRequestError.unavailable("Unknown workflow lane.")
                }
                try coordinator.setThreadWorkflowLane(lane, threadID: thread.id)
            case "section":
                let requested = parameters["sectionID"] ?? ""
                let section = threads.compactMap(\.sectionID).first { CompanionOperatorProjection.key("section", $0) == requested }
                guard requested == "none" || section != nil else { throw CompanionOperatorRequestError.unavailable("This Codex section is no longer available.") }
                try coordinator.moveCodexThread(thread.id, toSectionID: section)
                refresh()
            default: throw CompanionOperatorRequestError.unavailable("Unknown chat action.")
            }
            didChange()
            return nil
        }
        if let skill = coordinator.skills().first(where: { CompanionOperatorProjection.key("skill", $0.id) == itemID }) {
            switch operation {
            case "readSkill":
                do { return try CompanionOperatorProjection.skillContent(skill) }
                catch { throw CompanionOperatorRequestError.unavailable("The Mac could not read this skill. Refresh Operator and check that the file is still available.") }
            case "favourite":
                guard let enabled = parameters["enabled"].flatMap(Bool.init) else { throw CompanionOperatorRequestError.unavailable("Choose a favourite state.") }
                try coordinator.setFavourite(enabled, skillID: skill.id)
            case "tags":
                let tags = (parameters["tags"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard tags.count <= 20, tags.allSatisfy({ $0.count <= 60 }) else { throw CompanionOperatorRequestError.unavailable("Use up to 20 short tags.") }
                try coordinator.replaceTags(tags, skillID: skill.id)
            case "recordUse":
                try coordinator.recordSkillUse(SkillUseEvent(id: UUID().uuidString, skillID: skill.id, sessionID: nil, harnessID: nil, occurredAt: Date()))
            default: throw CompanionOperatorRequestError.unavailable("Unknown skill action.")
            }
            didChange()
            return nil
        }
        throw CompanionOperatorRequestError.unavailable("This Operator item is no longer available. Refresh and try again.")
    }
}
