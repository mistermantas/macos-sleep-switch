import Foundation

enum CompanionLiveMetric: String, Codable, CaseIterable, Identifiable {
    case cpu, memory, battery, agents, session
    var id: Self { self }
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .battery: "Battery"
        case .agents: "Agents"
        case .session: "Session timer"
        }
    }
    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .battery: "battery.100percent"
        case .agents: "terminal"
        case .session: "timer"
        }
    }
}

struct CompanionLiveActivityPreferences: Codable, Equatable {
    static let defaultsKey = "companionLiveActivityPreferences"
    var primaryMetric: CompanionLiveMetric = .agents
    var metrics: [CompanionLiveMetric] = [.agents, .cpu, .memory, .battery]
    var automaticManualSessions = true
    var automaticAgentActivity = false

    var displayedMetrics: [CompanionLiveMetric] {
        var seen: Set<CompanionLiveMetric> = []
        return ([primaryMetric] + metrics).filter { seen.insert($0).inserted }.prefix(4).map { $0 }
    }
    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }
    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

enum CompanionLiveActivityOrigin: String, Codable, Hashable {
    case monitoring, manualSession, agents
}

struct CompanionLiveActivityContentState: Codable, Hashable {
    // Original keys remain readable by activities started before this update.
    var macName: String
    var endsAt: Date?
    var isIndefinite: Bool
    var updatedAt: Date
    var primaryMetric: CompanionLiveMetric? = nil
    var metrics: [CompanionLiveMetric]? = nil
    var cpuPercent: Double? = nil
    var memoryPercent: Double? = nil
    var batteryPercent: Double? = nil
    var isCharging: Bool? = nil
    var activeSessionCount: Int? = nil
    var agentSummary: String? = nil
    var hasManualSession: Bool? = nil

    var displayedMetrics: [CompanionLiveMetric] { metrics ?? [.session] }
    var primary: CompanionLiveMetric { primaryMetric ?? .session }
    var staleDate: Date { updatedAt.addingTimeInterval(120) }

    func value(for metric: CompanionLiveMetric) -> String {
        switch metric {
        case .cpu: return Self.percent(cpuPercent)
        case .memory: return Self.percent(memoryPercent)
        case .battery: return Self.percent(batteryPercent)
        case .agents: return activeSessionCount.map { String(max(0, $0)) } ?? "—"
        case .session: return hasManualSession == false ? "Off" : endsAt == nil ? "On" : "Timer"
        }
    }
    private static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite, (0...100).contains(value) else { return "—" }
        return "\(Int(value.rounded()))%"
    }
}

struct CompanionSystemLoad: Codable, Equatable {
    let sampledAt: Date
    let cpuPercent: Double?
    let memoryUsedBytes: UInt64?
    let memoryTotalBytes: UInt64?
    var memoryPercent: Double? {
        guard let used = memoryUsedBytes, let total = memoryTotalBytes, total > 0, used <= total else { return nil }
        return Double(used) / Double(total) * 100
    }
}

enum CompanionSystemLoadMath {
    static func cpuPercent(previous: [UInt32], current: [UInt32]) -> Double? {
        guard previous.count == 4, current.count == 4 else { return nil }
        let delta = zip(current, previous).map { UInt64($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return nil }
        // Mach ordering: user, system, idle, nice. CPU load is normalized
        // across all processors, with wraparound handled for each counter.
        return Double(total - delta[2]) / Double(total) * 100
    }
    static func memoryUsed(active: UInt64, inactive: UInt64, wired: UInt64, compressed: UInt64,
                           purgeable: UInt64, fileBacked: UInt64, pageSize: UInt64, total: UInt64) -> UInt64? {
        guard pageSize > 0, total > 0 else { return nil }
        var resident: UInt64 = 0
        for pages in [active, inactive, wired, compressed] {
            let sum = resident.addingReportingOverflow(pages)
            guard !sum.overflow else { return nil }
            resident = sum.partialValue
        }
        let reclaimableSum = purgeable.addingReportingOverflow(fileBacked)
        guard !reclaimableSum.overflow else { return nil }
        let reclaimable = reclaimableSum.partialValue
        guard resident >= reclaimable else { return nil }
        let bytes = (resident - reclaimable).multipliedReportingOverflow(by: pageSize)
        guard !bytes.overflow else { return nil }
        return min(bytes.partialValue, total)
    }
}

/// Records an automatic start before ActivityKit can report a dismissal.
/// Persisting it prevents the same work session from reappearing after relaunch.
struct CompanionLiveActivityPolicy {
    var observedTriggers: [String: String] = [:]
    func shouldStart(deviceID: String, triggerID: String) -> Bool { observedTriggers[deviceID] != triggerID }
    mutating func markObserved(deviceID: String, triggerID: String) { observedTriggers[deviceID] = triggerID }
    mutating func observeFreshTrigger(deviceID: String, triggerID: String?) {
        if triggerID == nil { observedTriggers.removeValue(forKey: deviceID) }
    }
}
