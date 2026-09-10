import Foundation

enum CompanionOperatorProjection {
    static let sharingKey = "companionOperatorContentSharingEnabled"
    static let workflowLanes = ["Inbox", "Planned", "Doing", "Waiting", "Done"]

    static func key(_ category: String, _ localID: String) -> String {
        CompanionRemoteWorkSummary.pseudonymousID(harnessID: category, localID: localID)
    }

    static func make(
        sessions: [OperatorSession], threads: [CodexThreadMirror], skills: [OperatorSkillRecord],
        sources: [OperatorAdapterSnapshot], workflowLanes: [String: String], sharingEnabled: Bool,
        triggersEnabled: Bool, diagnosticsEnabled: Bool, historyEnabled: Bool, now: Date = Date()
    ) -> CompanionOperatorSnapshot {
        let threadIndex = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let orderedSessions = sessions.sorted { ($0.lastActivityAt ?? $0.startedAt) > ($1.lastActivityAt ?? $1.startedAt) }
        let projectedSessions = orderedSessions.prefix(200).map { original in
            let session = original.current(at: now)
            let thread = session.harnessID == "codex" ? threadIndex[session.id] : nil
            return CompanionOperatorSession(
                id: key(session.harnessID, session.id), harnessID: session.harnessID, harnessName: session.harnessName,
                state: session.remoteWorkState(now: now),
                startedAt: session.startedAt, updatedAt: session.lastActivityAt ?? session.startedAt,
                durationSeconds: session.durationSeconds, inputTokens: session.inputTokens, outputTokens: session.outputTokens,
                reasoningTokens: session.reasoningTokens, cachedTokens: session.cachedTokens,
                title: sharingEnabled ? thread.map { String($0.title.prefix(200)) } : nil,
                projectName: sharingEnabled ? thread?.projectName.map { String($0.prefix(100)) } : nil,
                threadID: sharingEnabled ? thread.map { key("thread", $0.id) } : nil
            )
        }
        let projectedThreads: [CompanionOperatorThread] = sharingEnabled ? threads.sorted { $0.updatedAt > $1.updatedAt }.prefix(180).map { thread in
            CompanionOperatorThread(id: key("thread", thread.id), title: String(thread.title.prefix(200)),
                projectName: thread.projectName.map { String($0.prefix(100)) }, sectionID: thread.sectionID.map { key("section", $0) },
                sectionName: thread.sectionName.map { String($0.prefix(100)) }, workflowLane: workflowLanes[thread.id] ?? "Inbox",
                isPinned: thread.isPinned, isArchived: thread.isArchived, state: thread.remoteWorkState(now: now),
                updatedAt: thread.updatedAt, activity: thread.recentActivity,
                folderID: thread.cwd.isEmpty ? nil : key("folder", thread.cwd),
                folderName: thread.cwd.isEmpty ? nil : String(URL(fileURLWithPath: thread.cwd).lastPathComponent.prefix(100)))
        } : []
        let projectedSkills: [CompanionOperatorSkill] = sharingEnabled ? skills.prefix(300).map {
            CompanionOperatorSkill(id: key("skill", $0.id), name: String($0.skill.name.prefix(160)), sourceGroup: String($0.skill.sourceGroup.prefix(80)),
                tags: $0.metadata.tags.prefix(20).map { String($0.prefix(60)) }, isFavourite: $0.metadata.isFavourite,
                useCount: $0.useCount, modifiedAt: $0.skill.modifiedAt)
        } : []
        var snapshot = CompanionOperatorSnapshot(updatedAt: now, sharingEnabled: sharingEnabled, sessions: projectedSessions,
            threads: projectedThreads, skills: projectedSkills,
            sources: sources.map { CompanionOperatorSource(id: $0.harnessID, name: $0.harnessName, status: $0.availability.displayTitle,
                capabilities: $0.capabilities.filter(\.isSupported).map { $0.kind.rawValue }) },
            totalSessionCount: sessions.count, totalThreadCount: sharingEnabled ? threads.count : 0,
            totalSkillCount: sharingEnabled ? skills.count : 0, triggersEnabled: triggersEnabled,
            diagnosticsEnabled: diagnosticsEnabled, historyEnabled: historyEnabled)
        while (try? CompanionJSON.encoder.encode(snapshot).count) ?? Int.max > 400_000 {
            if !snapshot.skills.isEmpty { snapshot.skills.removeLast() }
            else if !snapshot.threads.isEmpty { snapshot.threads.removeLast() }
            else if !snapshot.sessions.isEmpty { snapshot.sessions.removeLast() }
            else { break }
        }
        return snapshot
    }

    static func threadContent(_ thread: CodexThreadMirror) -> CompanionOperatorContent {
        let recent = thread.messages.suffix(100)
        var remaining = 180_000
        var messages: [CompanionOperatorMessage] = []
        var truncated = thread.messages.count > 100
        for message in recent.reversed() {
            let text = String(message.text.prefix(min(8_000, remaining)))
            truncated = truncated || text.count < message.text.count
            guard remaining > 0 else { truncated = true; break }
            remaining -= text.count
            messages.append(CompanionOperatorMessage(id: key("message", message.id), role: message.role.rawValue, text: text, createdAt: message.createdAt))
        }
        return CompanionOperatorContent(itemID: key("thread", thread.id), kind: "thread", title: String(thread.title.prefix(200)), text: nil, messages: messages.reversed(), isTruncated: truncated).bounded()
    }

    static func skillContent(_ skill: OperatorSkillRecord) throws -> CompanionOperatorContent {
        let handle = try FileHandle(forReadingFrom: skill.skill.sourceURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 180_001) ?? Data()
        return CompanionOperatorContent(itemID: key("skill", skill.id), kind: "skill", title: skill.skill.name,
            text: String(decoding: data.prefix(180_000), as: UTF8.self), messages: [], isTruncated: data.count > 180_000).bounded()
    }
}
