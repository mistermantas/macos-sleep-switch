import Foundation

struct CompanionWidgetSnapshot: Codable, Equatable {
    var macName: String
    var batteryPercent: Double?
    var temperatureCelsius: Double?
    var isCharging: Bool
    var activeSessionCount: Int
    var thermalState: String
    var updatedAt: Date
}

enum CompanionWidgetStore {
    static let appGroupIdentifier = "group.lt.mantas.sleepswitch"
    private static let key = "companionWidgetSnapshot"

    static func save(_ snapshot: CompanionWidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: appGroupIdentifier)?.set(data, forKey: key)
    }

    static func load() -> CompanionWidgetSnapshot? {
        guard let data = UserDefaults(suiteName: appGroupIdentifier)?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(CompanionWidgetSnapshot.self, from: data)
    }
}
