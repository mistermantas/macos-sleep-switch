import Foundation
import UserNotifications

@MainActor
final class CompanionHeatNotificationManager {
    static let enabledKey = "heatNotificationsEnabled"
    static let thresholdKey = "heatNotificationThreshold"
    static let thirtyMinuteKey = "heatNotificationThirtyMinutes"
    static let sixtyMinuteKey = "heatNotificationSixtyMinutes"

    private let defaults: UserDefaults
    private var hotSince: [String: Date] = [:]
    private var sentMilestones: Set<String> = []

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }
    var threshold: Double { Double(defaults.integer(forKey: Self.thresholdKey) == 0 ? 85 : defaults.integer(forKey: Self.thresholdKey)) }

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive])
            if granted { defaults.set(true, forKey: Self.enabledKey) }
            return granted
        } catch { return false }
    }

    func evaluate(_ macs: [CompanionMacStatus], now: Date = .now) {
        guard isEnabled else { return }
        let threshold = threshold
        let observedIDs = Set(macs.map(\.deviceID))
        hotSince = hotSince.filter { observedIDs.contains($0.key) }
        for mac in macs {
            guard let temperature = mac.cooling?.temperatureCelsius,
                  temperature >= threshold,
                  mac.cooling?.profile != "systemControl" else {
                hotSince[mac.deviceID] = nil
                sentMilestones = sentMilestones.filter { !$0.hasPrefix("\(mac.deviceID):") }
                continue
            }
            let since = hotSince[mac.deviceID] ?? now
            hotSince[mac.deviceID] = since
            let elapsed = now.timeIntervalSince(since)
            notifyIfNeeded(minutes: 30, elapsed: elapsed, mac: mac, temperature: temperature)
            notifyIfNeeded(minutes: 60, elapsed: elapsed, mac: mac, temperature: temperature)
        }
    }

    private func notifyIfNeeded(minutes: Int, elapsed: TimeInterval, mac: CompanionMacStatus, temperature: Double) {
        let enabled = defaults.object(forKey: minutes == 30 ? Self.thirtyMinuteKey : Self.sixtyMinuteKey) as? Bool ?? true
        let key = "\(mac.deviceID):\(minutes)"
        guard enabled, elapsed >= Double(minutes * 60), !sentMilestones.contains(key) else { return }
        sentMilestones.insert(key)
        let content = UNMutableNotificationContent()
        content.title = "\(mac.displayName) is still hot"
        content.body = "\(Int(temperature.rounded()))°C after \(minutes) minutes with \(mac.cooling?.profile == "aggressive" ? "Aggressive" : "manual") cooling."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: "sleep-switch-hot-\(key)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
