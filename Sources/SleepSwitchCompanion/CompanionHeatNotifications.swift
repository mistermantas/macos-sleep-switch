import Foundation
import UserNotifications

@MainActor
final class CompanionHeatNotificationManager {
    static let enabledKey = "heatNotificationsEnabled"
    static let thresholdKey = "heatNotificationThreshold"
    static let thirtyMinuteKey = "heatNotificationThirtyMinutes"
    static let sixtyMinuteKey = "heatNotificationSixtyMinutes"
    private static let stateKey = "heatNotificationState"

    private let defaults: UserDefaults
    private var states: [String: HotState]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.stateKey),
           let saved = try? JSONDecoder().decode([String: HotState].self, from: data) {
            states = saved
        } else {
            states = [:]
        }
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }
    var threshold: Double { Double(defaults.integer(forKey: Self.thresholdKey) == 0 ? 85 : defaults.integer(forKey: Self.thresholdKey)) }

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            if granted { defaults.set(true, forKey: Self.enabledKey) }
            return granted
        } catch { return false }
    }

    func evaluate(_ macs: [CompanionMacStatus], now: Date = .now) {
        guard isEnabled else { return }
        let threshold = threshold
        let observedIDs = Set(macs.map(\.deviceID))
        states = states.filter { observedIDs.contains($0.key) }
        for mac in macs {
            guard let temperature = mac.cooling?.temperatureCelsius,
                  temperature >= threshold,
                  mac.cooling?.profile != "systemControl",
                  !mac.isStale else {
                states[mac.deviceID] = nil
                continue
            }
            var state = states[mac.deviceID] ?? HotState(since: now, sentMilestones: [])
            let elapsed = now.timeIntervalSince(state.since)
            notifyIfNeeded(minutes: 30, elapsed: elapsed, mac: mac, temperature: temperature, state: &state)
            notifyIfNeeded(minutes: 60, elapsed: elapsed, mac: mac, temperature: temperature, state: &state)
            states[mac.deviceID] = state
        }
        persistStates()
    }

    private func notifyIfNeeded(
        minutes: Int,
        elapsed: TimeInterval,
        mac: CompanionMacStatus,
        temperature: Double,
        state: inout HotState
    ) {
        let enabled = defaults.object(forKey: minutes == 30 ? Self.thirtyMinuteKey : Self.sixtyMinuteKey) as? Bool ?? true
        guard enabled, elapsed >= Double(minutes * 60), !state.sentMilestones.contains(minutes) else { return }
        state.sentMilestones.insert(minutes)
        let content = UNMutableNotificationContent()
        content.title = "\(mac.displayName) is still hot"
        content.body = "\(Int(temperature.rounded()))°C after \(minutes) minutes with \(mac.cooling?.profile == "aggressive" ? "Aggressive" : "manual") cooling."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: "sleep-switch-hot-\(mac.deviceID)-\(minutes)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func persistStates() {
        guard let data = try? JSONEncoder().encode(states) else { return }
        defaults.set(data, forKey: Self.stateKey)
    }

    private struct HotState: Codable {
        let since: Date
        var sentMilestones: Set<Int>
    }
}
