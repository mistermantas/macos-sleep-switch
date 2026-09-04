import Foundation

struct CompanionWidgetSnapshot: Codable, Equatable {
    var deviceID: String? = nil
    var macName: String
    var batteryPercent: Double?
    var temperatureCelsius: Double?
    var fanRPM: Double? = nil
    var isCharging: Bool
    var activeSessionCount: Int
    var thermalState: String
    var updatedAt: Date
}

/// The data contract used by the iPhone app and its widget extension.
///
/// Widgets do not have a reliable continuous refresh budget. A new status pushed
/// through the companion updates their timeline immediately; this plan supplies
/// the predictable fifteen-minute fallback and keeps the selected computer stable
/// between those pushes.
struct CompanionWidgetRefreshPlan: Equatable {
    enum Freshness: Equatable {
        case noData
        case reporting
        case recent
        case stale
    }

    static let fallbackRefreshInterval: TimeInterval = 15 * 60
    static let reportingWindow: TimeInterval = 90
    static let staleAfter: TimeInterval = 5 * 60

    let snapshot: CompanionWidgetSnapshot?
    let freshness: Freshness
    let freshnessLabel: String
    let nextRefreshAt: Date

    static func make(
        snapshots: [CompanionWidgetSnapshot],
        configuredDeviceID: String?,
        defaultDeviceID: String?,
        now: Date = Date()
    ) -> CompanionWidgetRefreshPlan {
        let snapshot: CompanionWidgetSnapshot?
        if let configuredDeviceID {
            // A configured widget is an explicit promise. Showing another Mac is
            // worse than showing a concise unavailable state.
            snapshot = snapshots.first { $0.deviceID == configuredDeviceID }
        } else if let defaultDeviceID,
                  let defaultSnapshot = snapshots.first(where: { $0.deviceID == defaultDeviceID }) {
            snapshot = defaultSnapshot
        } else {
            snapshot = snapshots.max(by: { $0.updatedAt < $1.updatedAt })
        }

        let freshness = freshness(for: snapshot?.updatedAt, now: now)
        return CompanionWidgetRefreshPlan(
            snapshot: snapshot,
            freshness: freshness,
            freshnessLabel: freshnessLabel(for: snapshot?.updatedAt, freshness: freshness, now: now),
            nextRefreshAt: now.addingTimeInterval(fallbackRefreshInterval)
        )
    }

    private static func freshness(for updatedAt: Date?, now: Date) -> Freshness {
        guard let updatedAt else { return .noData }
        let age = max(0, now.timeIntervalSince(updatedAt))
        if age <= reportingWindow { return .reporting }
        if age <= staleAfter { return .recent }
        return .stale
    }

    private static func freshnessLabel(
        for updatedAt: Date?,
        freshness: Freshness,
        now: Date
    ) -> String {
        switch freshness {
        case .noData:
            return "No Mac report yet"
        case .reporting:
            return "Mac reporting"
        case .recent:
            return "Mac updated \(elapsedText(since: updatedAt!, now: now))"
        case .stale:
            return "Mac last reported \(elapsedText(since: updatedAt!, now: now))"
        }
    }

    private static func elapsedText(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 60 * 60 { return "\(seconds / 60)m ago" }
        if seconds < 24 * 60 * 60 { return "\(seconds / 3_600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

enum CompanionWidgetStore {
    static let appGroupIdentifier = "group.lt.mantas.sleepswitch"
    private static let key = "companionWidgetSnapshot"
    private static let collectionKey = "companionWidgetSnapshotCollection"

    private struct Collection: Codable {
        var macs: [CompanionWidgetSnapshot]
        var defaultDeviceID: String?
    }

    static func save(_ snapshot: CompanionWidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: appGroupIdentifier)?.set(data, forKey: key)
    }

    static func save(macs: [CompanionWidgetSnapshot], defaultDeviceID: String?) {
        let normalizedMacs = normalize(macs)
        let collection = Collection(macs: normalizedMacs, defaultDeviceID: defaultDeviceID)
        guard let data = try? JSONEncoder().encode(collection) else { return }
        let defaults = UserDefaults(suiteName: appGroupIdentifier)
        defaults?.set(data, forKey: collectionKey)

        if let selected = snapshot(for: defaultDeviceID, in: collection)
            ?? normalizedMacs.max(by: { $0.updatedAt < $1.updatedAt }) {
            save(selected)
        }
    }

    static func load() -> CompanionWidgetSnapshot? {
        guard let data = UserDefaults(suiteName: appGroupIdentifier)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CompanionWidgetSnapshot.self, from: data)
    }

    static func loadAll() -> [CompanionWidgetSnapshot] {
        guard let data = UserDefaults(suiteName: appGroupIdentifier)?.data(forKey: collectionKey) else {
            return load().map { [$0] } ?? []
        }
        let decoded = (try? JSONDecoder().decode(Collection.self, from: data))?.macs
            ?? (load().map { [$0] } ?? [])
        return normalize(decoded)
    }

    static func defaultDeviceID() -> String? {
        guard let data = UserDefaults(suiteName: appGroupIdentifier)?.data(forKey: collectionKey),
              let collection = try? JSONDecoder().decode(Collection.self, from: data) else {
            return load()?.deviceID
        }
        return collection.defaultDeviceID
    }

    static func defaultSnapshot() -> CompanionWidgetSnapshot? {
        guard let data = UserDefaults(suiteName: appGroupIdentifier)?.data(forKey: collectionKey),
              let collection = try? JSONDecoder().decode(Collection.self, from: data) else {
            return load()
        }
        return snapshot(for: collection.defaultDeviceID, in: collection) ?? collection.macs.first
    }

    static func snapshot(for deviceID: String?) -> CompanionWidgetSnapshot? {
        let macs = loadAll()
        guard let deviceID else { return defaultSnapshot() ?? macs.first }
        return macs.first { $0.deviceID == deviceID }
    }

    private static func snapshot(
        for deviceID: String?,
        in collection: Collection
    ) -> CompanionWidgetSnapshot? {
        guard let deviceID else { return nil }
        return collection.macs.first { $0.deviceID == deviceID }
    }

    private static func normalize(_ macs: [CompanionWidgetSnapshot]) -> [CompanionWidgetSnapshot] {
        var newestByID: [String: CompanionWidgetSnapshot] = [:]
        var anonymous: [CompanionWidgetSnapshot] = []

        for snapshot in macs {
            guard let deviceID = snapshot.deviceID, !deviceID.isEmpty else {
                anonymous.append(snapshot)
                continue
            }
            if let existing = newestByID[deviceID], existing.updatedAt >= snapshot.updatedAt {
                continue
            }
            newestByID[deviceID] = snapshot
        }

        return (Array(newestByID.values) + anonymous)
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.macName.localizedCaseInsensitiveCompare(rhs.macName) == .orderedAscending
            }
    }
}
