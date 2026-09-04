import Foundation
import UserNotifications

/// Keeps remote-work notifications low-volume. First sight of a session is a
/// baseline, not an alert; only an evidence-backed state transition can notify.
final class CompanionWorkNotificationManager {
    static let enabledKey = "remoteWorkNotificationsEnabled"
    static let finishedEnabledKey = "remoteWorkFinishedNotificationsEnabled"
    private static let stateKey = "remoteWorkNotificationState"

    private let defaults: UserDefaults
    private var states: [String: State]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.stateKey),
           let saved = try? JSONDecoder().decode([String: State].self, from: data) {
            states = saved
        } else {
            states = [:]
        }
    }

    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )
            if granted { defaults.set(true, forKey: Self.enabledKey) }
            return granted
        } catch {
            return false
        }
    }

    func evaluate(_ macs: [CompanionMacStatus]) {
        // A stale status must not erase the last trusted baseline. Otherwise a
        // later fresh snapshot could look like a new transition and page the
        // user for work that changed while the Mac was offline.
        let staleDevicePrefixes = macs
            .filter(\.isStale)
            .map { "\($0.deviceID)|" }
        var nextStates = states.filter { key, _ in
            staleDevicePrefixes.contains { key.hasPrefix($0) }
        }

        for mac in macs where !mac.isStale {
            for item in mac.remoteWork?.items ?? [] {
                let key = "\(mac.deviceID)|\(item.id)"
                let next = State(state: item.state)
                if let previous = states[key], previous.state != next.state,
                   let kind = CompanionWorkAttentionPolicy.kind(for: item.state),
                   shouldNotify(kind: kind) {
                    notify(kind: kind, mac: mac, item: item)
                }
                nextStates[key] = next
            }
        }

        states = nextStates
        persistStates()
    }

    private func shouldNotify(kind: CompanionWorkAttentionKind) -> Bool {
        guard isEnabled else { return false }
        return switch kind {
        case .required:
            true
        case .useful:
            defaults.bool(forKey: Self.finishedEnabledKey)
        }
    }

    private func notify(
        kind: CompanionWorkAttentionKind,
        mac: CompanionMacStatus,
        item: CompanionWorkItemSummary
    ) {
        let content = UNMutableNotificationContent()
        content.title = kind == .required
            ? "\(mac.displayName) needs attention"
            : "Work finished on \(mac.displayName)"
        content.body = "\(item.harnessName) is \(item.state.title.lowercased())."
        content.sound = .default
        let identifier = "sleep-switch-work-\(mac.deviceID)-\(item.id)-\(item.state.rawValue)"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }

    private func persistStates() {
        guard let data = try? JSONEncoder().encode(states) else { return }
        defaults.set(data, forKey: Self.stateKey)
    }

    private struct State: Codable, Equatable {
        let state: CompanionWorkState
    }
}
