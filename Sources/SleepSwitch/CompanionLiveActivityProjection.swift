import Foundation

enum CompanionLiveActivityProjection {
    static func activeSessionCount(_ mac: CompanionMacStatus) -> Int {
        mac.operatorSnapshot?.sessions.filter { $0.state == .active }.count ?? mac.activeSessionCount
    }
    static func automaticTrigger(for mac: CompanionMacStatus, preferences: CompanionLiveActivityPreferences, now: Date = Date()) -> (origin: CompanionLiveActivityOrigin, id: String)? {
        guard !mac.isStale(at: now) else { return nil }
        if preferences.automaticManualSessions, let session = mac.manualSession, (session.endsAt.map { $0 > now } ?? true) {
            return (.manualSession, "manual:\(session.startedAt.timeIntervalSince1970)")
        }
        if preferences.automaticAgentActivity, activeSessionCount(mac) > 0 { return (.agents, "agents") }
        return nil
    }
    static func shouldEnd(origin: CompanionLiveActivityOrigin, mac: CompanionMacStatus, preferences: CompanionLiveActivityPreferences, now: Date = Date()) -> Bool {
        guard !mac.isStale(at: now) else { return false }
        switch origin {
        case .monitoring: return false
        case .manualSession:
            guard preferences.automaticManualSessions, let session = mac.manualSession else { return true }
            return session.endsAt.map { $0 <= now } ?? false
        case .agents: return !preferences.automaticAgentActivity || activeSessionCount(mac) == 0
        }
    }
    static func content(for mac: CompanionMacStatus, preferences: CompanionLiveActivityPreferences, now: Date = Date()) -> CompanionLiveActivityContentState {
        let load = mac.systemLoad
        let freshLoad = load.map { abs(mac.lastSeen.timeIntervalSince($0.sampledAt)) <= 120 } == true
        let active = mac.operatorSnapshot?.sessions.filter { $0.state == .active } ?? []
        let harnesses = Dictionary(grouping: active, by: \.harnessName).map { "\($0.key) \($0.value.count)" }.sorted()
        let session = mac.manualSession
        return CompanionLiveActivityContentState(macName: String(decoding: mac.displayName.utf8.prefix(96), as: UTF8.self), endsAt: session?.endsAt,
            isIndefinite: session != nil && session?.endsAt == nil, updatedAt: mac.lastSeen,
            primaryMetric: preferences.primaryMetric, metrics: preferences.displayedMetrics,
            cpuPercent: freshLoad ? load?.cpuPercent : nil, memoryPercent: freshLoad ? load?.memoryPercent : nil,
            batteryPercent: mac.batteryPercent, isCharging: mac.isCharging,
            activeSessionCount: activeSessionCount(mac), agentSummary: harnesses.isEmpty ? nil : String(decoding: harnesses.joined(separator: " · ").utf8.prefix(128), as: UTF8.self),
            hasManualSession: session.map { $0.endsAt.map { $0 > now } ?? true } ?? false)
    }
}
