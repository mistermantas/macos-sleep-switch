import ActivityKit
import Combine
import Foundation
import UIKit

@MainActor
final class CompanionLiveActivityController: ObservableObject {
    static let shared = CompanionLiveActivityController()
    @Published private(set) var preferences = CompanionLiveActivityPreferences.load()
    @Published private(set) var activeDeviceIDs: Set<String> = []
    @Published private(set) var busyDeviceIDs: Set<String> = []
    @Published private(set) var issue: String?

    private let defaults: UserDefaults
    private var policy: CompanionLiveActivityPolicy
    private var latestMacs: [String: CompanionMacStatus] = [:]
    private var operation: Task<Void, Never>?
    private var observers: [String: Task<Void, Never>] = [:]
    private var automaticDeviceID: String?
    private typealias LiveActivity = Activity<ManualSessionActivityAttributes>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = .load(from: defaults)
        policy = CompanionLiveActivityPolicy(observedTriggers: defaults.dictionary(forKey: "liveActivityObservedTriggers") as? [String: String] ?? [:])
        refreshActivities()
    }

    var activitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    func clearIssue() { issue = nil }

    func setPreferences(_ updated: CompanionLiveActivityPreferences) {
        preferences = updated
        preferences.save(to: defaults)
        Task {
            await enqueue { [self] in await apply(allowAutomaticStart: true) }
        }
    }

    /// All ActivityKit mutations are serialized, including background refresh,
    /// settings changes and user actions. A delayed refresh cannot race a stop.
    private func enqueue(_ action: @escaping @MainActor () async -> Void) async {
        let previous = operation
        let next = Task { @MainActor in
            await previous?.value
            await action()
        }
        operation = next
        await next.value
    }

    func synchronize(with macs: [CompanionMacStatus], automaticDeviceID: String? = nil, allowAutomaticStart: Bool = false) async {
        await enqueue { [self] in
            for mac in CompanionMacSelection.canonicalDevices(macs) {
                if let existing = latestMacs[mac.deviceID], existing.lastSeen > mac.lastSeen { continue }
                latestMacs[mac.deviceID] = mac
            }
            if allowAutomaticStart { self.automaticDeviceID = automaticDeviceID }
            await apply(allowAutomaticStart: allowAutomaticStart)
        }
    }

    func startMonitoring(_ mac: CompanionMacStatus) async {
        guard !busyDeviceIDs.contains(mac.deviceID) else { return }
        busyDeviceIDs.insert(mac.deviceID)
        defer { busyDeviceIDs.remove(mac.deviceID) }
        await enqueue { [self] in
            issue = nil
            guard activitiesEnabled else {
                issue = "Live Activities are off. Enable them in iPhone Settings → Apps → Sleep Switch → Live Activities."
                return
            }
            guard !mac.isStale else { issue = "Refresh this Mac before starting a Live Activity."; return }
            latestMacs[mac.deviceID] = mac
            // Explicit monitoring outlives manual sessions and agent work.
            for activity in currentActivities where activity.attributes.deviceID == mac.deviceID {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            request(for: mac, origin: .monitoring, triggerID: nil)
            if let trigger = CompanionLiveActivityProjection.automaticTrigger(for: mac, preferences: preferences) {
                policy.markObserved(deviceID: mac.deviceID, triggerID: trigger.id)
            }
            savePolicy()
            refreshActivities()
        }
    }

    func stopMonitoring(deviceID: String) async {
        guard !busyDeviceIDs.contains(deviceID) else { return }
        busyDeviceIDs.insert(deviceID)
        defer { busyDeviceIDs.remove(deviceID) }
        await enqueue { [self] in
            if let mac = latestMacs[deviceID], let trigger = CompanionLiveActivityProjection.automaticTrigger(for: mac, preferences: preferences) {
                policy.markObserved(deviceID: deviceID, triggerID: trigger.id)
            }
            savePolicy()
            for activity in currentActivities where activity.attributes.deviceID == deviceID {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            refreshActivities()
        }
    }

    func endAll() async {
        await enqueue { [self] in
            for activity in currentActivities { await activity.end(nil, dismissalPolicy: .immediate) }
            latestMacs.removeAll()
            automaticDeviceID = nil
            refreshActivities()
        }
    }

    private var currentActivities: [LiveActivity] {
        LiveActivity.activities.filter { $0.activityState == .active || $0.activityState == .stale }
    }

    private func apply(allowAutomaticStart: Bool) async {
        let now = Date()
        for activity in currentActivities {
            guard let deviceID = activity.attributes.deviceID else {
                // The old timer had no device identity, so it cannot be safely
                // rebound when more than one Mac is paired.
                await activity.end(nil, dismissalPolicy: .immediate)
                continue
            }
            guard let mac = latestMacs[deviceID], mac.lastSeen >= activity.content.state.updatedAt else { continue }
            if CompanionLiveActivityProjection.shouldEnd(origin: activity.attributes.origin ?? .manualSession,
                mac: mac, preferences: preferences, now: now) {
                await activity.end(nil, dismissalPolicy: .immediate)
            } else {
                let state = CompanionLiveActivityProjection.content(for: mac, preferences: preferences)
                if state != activity.content.state { await activity.update(ActivityContent(state: state, staleDate: state.staleDate)) }
            }
        }
        for mac in latestMacs.values where !mac.isStale(at: now) {
            let trigger = CompanionLiveActivityProjection.automaticTrigger(for: mac, preferences: preferences, now: now)
            policy.observeFreshTrigger(deviceID: mac.deviceID, triggerID: trigger?.id)
            guard let trigger else { continue }
            if currentActivities.contains(where: { $0.attributes.deviceID == mac.deviceID }) {
                policy.markObserved(deviceID: mac.deviceID, triggerID: trigger.id)
            } else if allowAutomaticStart, mac.deviceID == automaticDeviceID,
                      UIApplication.shared.applicationState == .active, activitiesEnabled,
                      policy.shouldStart(deviceID: mac.deviceID, triggerID: trigger.id) {
                if request(for: mac, origin: trigger.origin, triggerID: trigger.id) {
                    policy.markObserved(deviceID: mac.deviceID, triggerID: trigger.id)
                }
            }
        }
        savePolicy()
        refreshActivities()
    }

    @discardableResult
    private func request(for mac: CompanionMacStatus, origin: CompanionLiveActivityOrigin, triggerID: String?) -> Bool {
        let state = CompanionLiveActivityProjection.content(for: mac, preferences: preferences)
        do {
            let attributes = ManualSessionActivityAttributes(macName: state.macName,
                deviceID: mac.deviceID, origin: origin, startedAt: Date(), automaticTriggerID: triggerID)
            let payloadSize = try JSONEncoder().encode(attributes).count + JSONEncoder().encode(state).count
            guard payloadSize < 4096 else {
                issue = "This Mac’s Live Activity data is too large. Refresh the Mac and try again."
                return false
            }
            _ = try LiveActivity.request(attributes: attributes,
                content: ActivityContent(state: state, staleDate: state.staleDate), pushType: nil)
            return true
        } catch {
            issue = "Couldn’t start the Live Activity. \(error.localizedDescription)"
            return false
        }
    }

    private func savePolicy() { defaults.set(policy.observedTriggers, forKey: "liveActivityObservedTriggers") }

    private func refreshActivities() {
        let activities = currentActivities
        activeDeviceIDs = Set(activities.compactMap { $0.attributes.deviceID })
        let ids = Set(activities.map(\.id))
        for id in Array(observers.keys) where !ids.contains(id) { observers.removeValue(forKey: id)?.cancel() }
        for activity in activities where observers[activity.id] == nil {
            observers[activity.id] = Task { [weak self] in
                for await _ in activity.activityStateUpdates {
                    guard !Task.isCancelled else { return }
                    self?.refreshActivities()
                }
            }
        }
    }
}
