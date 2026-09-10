#if DEBUG && targetEnvironment(simulator)
import ActivityKit
import Foundation

/// Simulator-only end-to-end checks against ActivityKit. Fixture snapshots never
/// enter the CloudKit command path or change the Mac's power/cooling settings.
@MainActor
enum CompanionLiveActivityIntegrationChecks {
    static func run(mac fixture: CompanionMacStatus) async {
        let controller = CompanionLiveActivityController.shared
        let saved = controller.preferences
        var results: [String: Bool] = [:]
        func activity(_ id: String) -> Activity<ManualSessionActivityAttributes>? {
            Activity<ManualSessionActivityAttributes>.activities.first {
                $0.attributes.deviceID == id && ($0.activityState == .active || $0.activityState == .stale)
            }
        }
        func check(_ name: String, _ condition: @escaping () -> Bool) async {
            for _ in 0..<30 {
                if condition() { results[name] = true; return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            results[name] = false
        }
        await controller.endAll()
        controller.setPreferences(.init())
        var mac = fixture.refreshingLastSeen()
        mac.manualSession = CompanionManualSessionStatus(startedAt: Date(), endsAt: Date().addingTimeInterval(600))
        await controller.startMonitoring(mac)
        await check("manual start", { activity(mac.deviceID)?.attributes.origin == .monitoring })
        let originalID = activity(mac.deviceID)?.id
        var otherJSON = try! JSONSerialization.jsonObject(with: CompanionJSON.encoder.encode(mac)) as! [String: Any]
        otherJSON["deviceID"] = "another-fixture-mac"
        otherJSON["displayName"] = "Another Mac"
        let other = try! CompanionJSON.decoder.decode(CompanionMacStatus.self, from: JSONSerialization.data(withJSONObject: otherJSON))
        await controller.synchronize(with: [other], automaticDeviceID: other.deviceID)
        await check("selection stays pinned", { activity(mac.deviceID)?.id == originalID && activity(mac.deviceID)?.content.state.macName == mac.displayName && activity(other.deviceID) == nil })
        let old = mac
        mac = mac.refreshingLastSeen(at: Date().addingTimeInterval(1))
        mac.systemLoad = CompanionSystemLoad(sampledAt: mac.lastSeen, cpuPercent: 72, memoryUsedBytes: 33, memoryTotalBytes: 100)
        await controller.synchronize(with: [mac])
        await check("background refresh updates readings", { activity(mac.deviceID)?.content.state.cpuPercent == 72 })
        await controller.synchronize(with: [old])
        await check("older refresh cannot roll readings back", { activity(mac.deviceID)?.content.state.cpuPercent == 72 })
        var preferences = controller.preferences
        preferences.primaryMetric = .battery
        preferences.metrics = [.battery, .cpu]
        controller.setPreferences(preferences)
        await controller.synchronize(with: [mac])
        await check("configuration updates existing activity", { activity(mac.deviceID)?.content.state.primary == .battery && activity(mac.deviceID)?.content.state.displayedMetrics == [.battery, .cpu] })
        await controller.stopMonitoring(deviceID: mac.deviceID)
        await check("manual stop", { activity(mac.deviceID) == nil && !controller.activeDeviceIDs.contains(mac.deviceID) })
        await controller.synchronize(with: [mac], automaticDeviceID: mac.deviceID, allowAutomaticStart: true)
        await check("stopped session does not restart", { activity(mac.deviceID) == nil })
        mac.manualSession = CompanionManualSessionStatus(startedAt: Date().addingTimeInterval(2), endsAt: Date().addingTimeInterval(600))
        mac = mac.refreshingLastSeen(at: Date().addingTimeInterval(2))
        await controller.synchronize(with: [mac], automaticDeviceID: mac.deviceID, allowAutomaticStart: true)
        await check("next manual session starts automatically", { activity(mac.deviceID)?.attributes.origin == .manualSession })
        mac.manualSession = nil
        mac = mac.refreshingLastSeen(at: Date().addingTimeInterval(3))
        await controller.synchronize(with: [mac])
        await check("automatic timer ends with its session", { activity(mac.deviceID) == nil })
        preferences.automaticAgentActivity = true
        controller.setPreferences(preferences)
        await controller.synchronize(with: [mac], automaticDeviceID: mac.deviceID, allowAutomaticStart: true)
        await check("agent activity starts automatically", { activity(mac.deviceID)?.attributes.origin == .agents })
        await controller.startMonitoring(mac)
        await controller.startMonitoring(mac)
        await check("repeated start remains one activity", {
            Activity<ManualSessionActivityAttributes>.activities.filter { $0.attributes.deviceID == mac.deviceID && ($0.activityState == .active || $0.activityState == .stale) }.count == 1
        })
        mac.operatorSnapshot?.sessions = []
        mac = mac.refreshingLastSeen(at: Date().addingTimeInterval(4))
        await controller.synchronize(with: [mac])
        await check("monitoring survives finished agents", { activity(mac.deviceID)?.attributes.origin == .monitoring })
        await controller.endAll()
        await check("account unavailable clears activities", { controller.activeDeviceIDs.isEmpty })
        controller.setPreferences(saved)
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("live-activity-checks.json")
        try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
}
#endif
