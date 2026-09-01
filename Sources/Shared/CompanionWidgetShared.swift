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
        let collection = Collection(macs: macs, defaultDeviceID: defaultDeviceID)
        guard let data = try? JSONEncoder().encode(collection) else { return }
        let defaults = UserDefaults(suiteName: appGroupIdentifier)
        defaults?.set(data, forKey: collectionKey)

        if let selected = snapshot(for: defaultDeviceID, in: collection) ?? macs.first {
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
        return (try? JSONDecoder().decode(Collection.self, from: data))?.macs
            ?? (load().map { [$0] } ?? [])
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
}
