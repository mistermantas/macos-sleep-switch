import Foundation

enum CompanionLiveActivityTests {
    static func run() {
        testHostCounters()
        testCompatibleStatusAndContent()
        testAutomaticLifecycleAndDismissal()
        print("Live Activity tests passed")
    }
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError("Live Activity: " + message) }
    }
    private static func testHostCounters() {
        expect(CompanionSystemLoadMath.cpuPercent(previous: [100, 100, 100, 100], current: [120, 110, 160, 110]) == 40, "CPU uses busy ticks over total, including nice and all processors")
        expect(CompanionSystemLoadMath.cpuPercent(previous: [0, 0, 0, 0], current: [0, 0, 100, 0]) == 0, "a real idle reading is zero")
        expect(CompanionSystemLoadMath.cpuPercent(previous: [0, 0, 0, 0], current: [0, 0, 0, 0]) == nil, "no sample interval is unavailable")
        expect(CompanionSystemLoadMath.cpuPercent(previous: [], current: [1, 2, 3, 4]) == nil, "first CPU sample needs a baseline")
        expect(CompanionSystemLoadMath.cpuPercent(previous: [UInt32.max - 4, 0, UInt32.max - 4, 0], current: [5, 0, 5, 0]) == 50, "32-bit counter wrap is handled")
        expect(CompanionSystemLoadMath.memoryUsed(active: 40, inactive: 20, wired: 10, compressed: 10, purgeable: 5, fileBacked: 15, pageSize: 4096, total: 409600) == 60 * 4096, "reclaimable file cache is excluded from used memory")
        expect(CompanionSystemLoadMath.memoryUsed(active: 0, inactive: 0, wired: 0, compressed: 0, purgeable: 1, fileBacked: 0, pageSize: 4096, total: 409600) == nil, "invalid counters never underflow")
        expect(CompanionSystemLoadMath.memoryUsed(active: .max, inactive: 1, wired: 0, compressed: 0, purgeable: 0, fileBacked: 0, pageSize: 4096, total: 409600) == nil, "corrupt counters never overflow")
        let sampler = SystemLoadSampler()
        let sample = sampler.sample()
        expect(sample.cpuPercent == nil, "host sampler doesn't invent an initial CPU rate")
        expect(sample.memoryPercent.map { (0...100).contains($0) } == true, "read-only host API supplies real memory data")
        expect(sampler.sample(at: sample.sampledAt.addingTimeInterval(0.5)) == sample, "sampling is bounded even when commands request more snapshots")
        let next = sampler.sample(at: sample.sampledAt.addingTimeInterval(2))
        expect(next.cpuPercent.map { (0...100).contains($0) } ?? true, "CPU counters return a normalized percentage or unavailable")
    }
    private static func testCompatibleStatusAndContent() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var mac = CompanionMacStatus.unavailable.refreshingLastSeen(at: now)
        mac.systemLoad = CompanionSystemLoad(sampledAt: now, cpuPercent: 41, memoryUsedBytes: 60, memoryTotalBytes: 100)
        let encoded = try! CompanionJSON.encoder.encode(mac)
        expect(try! CompanionJSON.decoder.decode(CompanionMacStatus.self, from: encoded) == mac, "new Mac readings survive CloudKit encoding")
        var legacy = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "systemLoad")
        let old = try! CompanionJSON.decoder.decode(CompanionMacStatus.self, from: JSONSerialization.data(withJSONObject: legacy))
        expect(old.systemLoad == nil, "older Macs decode without load readings")
        expect(mac.refreshingLastSeen().systemLoad == mac.systemLoad, "heartbeat retains the actual sample timestamp")
        expect(mac.applyingKeepAwake(parameters: ["enabled": "false"]).systemLoad == mac.systemLoad, "command projection preserves load readings")
        let content = CompanionLiveActivityProjection.content(for: mac, preferences: .init(), now: now)
        expect(content.value(for: .cpu) == "41%" && content.value(for: .memory) == "60%", "real CPU and memory are displayed")
        expect(content.updatedAt == now && content.staleDate == now.addingTimeInterval(120), "freshness uses the Mac timestamp, not the iPhone refresh")
        let staleSample = CompanionLiveActivityProjection.content(for: mac.refreshingLastSeen(at: now.addingTimeInterval(121)), preferences: .init())
        expect(staleSample.value(for: .cpu) == "—", "an old CPU sample is not disguised as a new reading")
        let missing = CompanionLiveActivityProjection.content(for: old, preferences: .init())
        expect(missing.value(for: .cpu) == "—" && missing.value(for: .battery) == "—", "absent readings don't become zero")
        let legacyState = CompanionLiveActivityContentState(macName: "Mac", endsAt: nil, isIndefinite: true, updatedAt: now)
        expect(try! JSONDecoder().decode(CompanionLiveActivityContentState.self, from: JSONEncoder().encode(legacyState)).primary == .session, "old timer content remains readable")
        var preferences = CompanionLiveActivityPreferences()
        preferences.primaryMetric = .session
        preferences.metrics = [.agents, .cpu, .cpu, .memory, .battery]
        expect(preferences.displayedMetrics == [.session, .agents, .cpu, .memory], "primary is always visible, deduplicated and capped at four metrics")
        var object = try! JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object["displayName"] = String(repeating: "\u{0001}👩‍💻", count: 10_000)
        let huge = try! CompanionJSON.decoder.decode(CompanionMacStatus.self, from: JSONSerialization.data(withJSONObject: object))
        let bounded = CompanionLiveActivityProjection.content(for: huge, preferences: preferences)
        // Include duplicate name in attributes and a generous allowance for
        // device identity + automatic trigger fields.
        expect((try! JSONEncoder().encode(bounded)).count + bounded.macName.utf8.count * 6 + 1000 < 4096, "complex Unicode and JSON escaping fit ActivityKit's combined 4 KB budget")
    }
    private static func testAutomaticLifecycleAndDismissal() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var mac = CompanionMacStatus.unavailable.refreshingLastSeen(at: now)
        var preferences = CompanionLiveActivityPreferences()
        mac.manualSession = CompanionManualSessionStatus(startedAt: now, endsAt: now.addingTimeInterval(600))
        let first = CompanionLiveActivityProjection.automaticTrigger(for: mac, preferences: preferences, now: now)!
        expect(first.origin == .manualSession, "existing manual session automation is preserved")
        var policy = CompanionLiveActivityPolicy()
        expect(policy.shouldStart(deviceID: mac.deviceID, triggerID: first.id), "new work may start an activity")
        policy.markObserved(deviceID: mac.deviceID, triggerID: first.id)
        policy = CompanionLiveActivityPolicy(observedTriggers: policy.observedTriggers)
        expect(!policy.shouldStart(deviceID: mac.deviceID, triggerID: first.id), "stop or dismissal stays suppressed after app relaunch")
        expect(policy.shouldStart(deviceID: "another-mac", triggerID: first.id), "dismissal is scoped to the chosen Mac")
        expect(!CompanionLiveActivityProjection.shouldEnd(origin: .monitoring, mac: mac, preferences: preferences, now: now), "manual monitoring isn't tied to keep-awake work")
        mac.manualSession = nil
        expect(CompanionLiveActivityProjection.shouldEnd(origin: .manualSession, mac: mac, preferences: preferences, now: now), "acknowledged end closes automatic timer")
        expect(!CompanionLiveActivityProjection.shouldEnd(origin: .monitoring, mac: mac, preferences: preferences, now: now), "monitoring survives ending the manual session")
        expect(!CompanionLiveActivityProjection.shouldEnd(origin: .manualSession, mac: mac, preferences: preferences, now: now.addingTimeInterval(600)), "missing fresh data doesn't falsely end an activity")
        policy.observeFreshTrigger(deviceID: mac.deviceID, triggerID: nil)
        expect(policy.shouldStart(deviceID: mac.deviceID, triggerID: first.id), "fresh idle state permits the next agent cycle")
        mac.manualSession = CompanionManualSessionStatus(startedAt: now, endsAt: now.addingTimeInterval(-1))
        expect(CompanionLiveActivityProjection.automaticTrigger(for: mac, preferences: preferences, now: now) == nil, "expired timers cannot restart")
        preferences.automaticAgentActivity = true
        let session = CompanionOperatorSession(id: "active", harnessID: "codex", harnessName: "Codex", state: .active, startedAt: now, updatedAt: now, durationSeconds: 0, inputTokens: 0, outputTokens: 0, reasoningTokens: 0, cachedTokens: 0, title: nil, projectName: nil, threadID: nil)
        mac.operatorSnapshot = CompanionOperatorSnapshot(updatedAt: now, sharingEnabled: false, sessions: [session], threads: [], skills: [], sources: [], totalSessionCount: 34, totalThreadCount: 0, totalSkillCount: 0, triggersEnabled: false, diagnosticsEnabled: false, historyEnabled: true)
        expect(CompanionLiveActivityProjection.activeSessionCount(mac) == 1, "agent metric uses current activity, not historical totals")
        expect(CompanionLiveActivityProjection.automaticTrigger(for: mac, preferences: preferences, now: now)?.origin == .agents, "agent automation is opt-in")
        expect(CompanionLiveActivityProjection.automaticTrigger(for: mac, preferences: preferences, now: now.addingTimeInterval(600)) == nil, "stale Mac data cannot start a live activity")
        mac.operatorSnapshot?.sessions = []
        expect(CompanionLiveActivityProjection.shouldEnd(origin: .agents, mac: mac, preferences: preferences, now: now), "agent activity ends when current sessions finish")
    }
}
