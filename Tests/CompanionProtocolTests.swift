import Foundation

enum CompanionProtocolTests {
    static func run() {
        testPreciseElapsedTimeText()
        testCommandProgressStages()
        testContextTransferHistoryKeepsLatestState()
        testContextTransferHistoryFiltersByDevice()
        testSelectsFreshReplacementForStalePersistedMac()
        testDoesNotSwitchAStaleSelectionToAnotherMac()
        testWidgetRefreshPlan()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let capabilities = CompanionMacCapabilities(
            canSleepMac: true,
            canSleepDisplay: false,
            canWakeDisplay: true,
            canLockMac: false,
            canRestartMac: false,
            canShutdownMac: false,
            canSetKeepAwake: false,
            canSleepDisplayUntilAgentsFinish: false,
            supportsCloudKit: false
        )
        let command = CompanionRemoteCommand(
            id: UUID(),
            targetDeviceID: "mac-1",
            action: .sleepMac,
            parameters: [:],
            requesterDeviceID: "iphone-1",
            nonce: "nonce-1",
            createdAt: now.addingTimeInterval(-10),
            expiresAt: now.addingTimeInterval(60),
            policyVersion: 1
        )

        let accepted = CompanionCommandPolicy.validate(
            command,
            targetDeviceID: "mac-1",
            capabilities: capabilities,
            now: now
        )
        expect(isSuccess(accepted), "accepts an unexpired supported command")

        let wrongDevice = CompanionCommandPolicy.validate(
            command,
            targetDeviceID: "other-mac",
            capabilities: capabilities,
            now: now
        )
        expect(isFailure(wrongDevice, .wrongDevice), "rejects a command for another Mac")

        let replay = CompanionCommandPolicy.validate(
            command,
            targetDeviceID: "mac-1",
            capabilities: capabilities,
            now: now,
            seenNonces: ["nonce-1"]
        )
        expect(isFailure(replay, .replay), "rejects a replayed nonce")

        let expired = CompanionRemoteCommand(
            id: command.id,
            targetDeviceID: command.targetDeviceID,
            action: command.action,
            parameters: command.parameters,
            requesterDeviceID: command.requesterDeviceID,
            nonce: command.nonce,
            createdAt: now.addingTimeInterval(-120),
            expiresAt: now.addingTimeInterval(-1),
            policyVersion: command.policyVersion
        )
        let expiredResult = CompanionCommandPolicy.validate(
            expired,
            targetDeviceID: "mac-1",
            capabilities: capabilities,
            now: now
        )
        expect(isFailure(expiredResult, .expired), "rejects an expired command")

        let unsupported = CompanionRemoteCommand(
            id: UUID(),
            targetDeviceID: "mac-1",
            action: .shutdownMac,
            parameters: [:],
            requesterDeviceID: "iphone-1",
            nonce: "nonce-2",
            createdAt: now,
            expiresAt: now.addingTimeInterval(60),
            policyVersion: 1
        )
        let unsupportedResult = CompanionCommandPolicy.validate(
            unsupported,
            targetDeviceID: "mac-1",
            capabilities: capabilities,
            now: now
        )
        expect(
            isFailure(unsupportedResult, .unsupportedAction),
            "rejects a capability-gated destructive command"
        )

        let appStoreCapabilities = CompanionMacCapabilities(
            canSleepMac: true,
            canSleepDisplay: false,
            canWakeDisplay: true,
            canWakeMac: false,
            canLockMac: false,
            canRestartMac: false,
            canShutdownMac: false,
            canSetKeepAwake: true,
            canSleepDisplayUntilAgentsFinish: false,
            supportsCloudKit: true,
            canControlManualSession: true,
            canSetCoolingProfile: true,
            canPreventSleepWithLidClosed: false
        )
        expect(
            appStoreCapabilities.availableActions.contains(.wakeDisplay),
            "exposes wake display in the sandboxed build"
        )
        expect(
            !appStoreCapabilities.availableActions.contains(.wakeMac),
            "does not pretend CloudKit can wake a fully sleeping Mac"
        )
        expect(
            appStoreCapabilities.availableActions.contains(.startManualSession),
            "advertises manual-session control when supported"
        )
        expect(
            appStoreCapabilities.availableActions.contains(.setCoolingProfile),
            "advertises safe cooling profiles when supported"
        )

        let status = CompanionMacStatus(
            deviceID: "mac-1",
            displayName: "Build Mac",
            build: "2.2.0 (16)",
            lastSeen: now,
            uptimeSeconds: 1_800,
            powerSource: .ac,
            batteryPercent: 100,
            thermalState: "nominal",
            activeAgentCount: 1,
            activeSessionCount: 2,
            awakeMode: "preventSleep",
            displayAsleep: false,
            isKeepingAwake: true,
            keepDisplayAwake: false,
            automaticAgentAwakeEnabled: true,
            wakeDisplayWhenAgentsFinish: false,
            estimatedWatts: 42,
            energySource: .ac,
            energyConfidence: .estimated,
            isCharging: true,
            capabilities: appStoreCapabilities,
            agents: [CompanionAgentStatus(id: "opencode", name: "OpenCode", sessionCount: 2)],
            manualSession: CompanionManualSessionStatus(startedAt: now, endsAt: nil),
            cooling: CompanionCoolingStatus(
                profile: "aggressive",
                state: "Aggressive",
                temperatureCelsius: 58,
                verifiedDemand: 0.7,
                fans: [CompanionFanStatus(id: 0, actualRPM: 4_500, targetRPM: 4_600, maximumRPM: 6_000)],
                message: nil,
                availableProfiles: ["systemControl", "aggressive", "maximum"]
            ),
            operatorSummary: CompanionOperatorSummary(
                updatedAt: now,
                harnesses: [
                    CompanionOperatorHarnessSummary(
                        harnessID: "codex",
                        harnessName: "Codex",
                        liveSessionCount: 2,
                        tokenDelta: 14_200,
                        durationDeltaSeconds: 1_800
                    )
                ],
                activeSessionCount: 2,
                tokenDelta: 14_200,
                durationDeltaSeconds: 1_800,
                finishAction: CompanionRemoteAction.sleepMacWhenAgentsFinish.rawValue,
                alertCodes: ["operator.hermes-agent.permission_required"]
            ),
            remoteWork: CompanionRemoteWorkSummary(
                updatedAt: now,
                items: [
                    CompanionWorkItemSummary(
                        id: "private-work-item",
                        harnessID: "codex",
                        harnessName: "Codex",
                        state: .reviewReady,
                        startedAt: now.addingTimeInterval(-1_800),
                        updatedAt: now.addingTimeInterval(-60),
                        durationSeconds: 1_740,
                        title: nil
                    )
                ],
                stateCounts: [CompanionWorkStateCount(state: .reviewReady, count: 1)],
                attentionCount: 0
            )
        )
        expect(
            status.refreshingLastSeen(at: now.addingTimeInterval(5)).lastSeen
                == now.addingTimeInterval(5),
            "refreshes a status heartbeat without changing its payload"
        )
        let encodedStatus = try! CompanionJSON.encoder.encode(status)
        let decodedStatus = try! CompanionJSON.decoder.decode(
            CompanionMacStatus.self,
            from: encodedStatus
        )
        expect(decodedStatus == status, "round-trips detailed companion telemetry")

        let workItemWithProject = CompanionWorkItemSummary(
            id: "private-work-item",
            harnessID: "codex",
            harnessName: "Codex",
            state: .active,
            startedAt: now.addingTimeInterval(-90),
            updatedAt: now,
            durationSeconds: 90,
            title: "Approved title",
            projectName: "Approved project"
        )
        var legacyWorkItem = try! JSONSerialization.jsonObject(
            with: CompanionJSON.encoder.encode(workItemWithProject)
        ) as! [String: Any]
        legacyWorkItem.removeValue(forKey: "projectName")
        let decodedLegacyWorkItem = try! CompanionJSON.decoder.decode(
            CompanionWorkItemSummary.self,
            from: JSONSerialization.data(withJSONObject: legacyWorkItem)
        )
        expect(
            decodedLegacyWorkItem.projectName == nil,
            "decodes remote work records written before project labels existed"
        )

        var legacyObject = try! JSONSerialization.jsonObject(with: encodedStatus) as! [String: Any]
        legacyObject.removeValue(forKey: "agents")
        legacyObject.removeValue(forKey: "manualSession")
        legacyObject.removeValue(forKey: "cooling")
        legacyObject.removeValue(forKey: "operatorSummary")
        legacyObject.removeValue(forKey: "remoteWork")
        if var legacyCapabilities = legacyObject["capabilities"] as? [String: Any] {
            legacyCapabilities.removeValue(forKey: "canControlManualSession")
            legacyCapabilities.removeValue(forKey: "canSetCoolingProfile")
            legacyObject["capabilities"] = legacyCapabilities
        }
        let legacyData = try! JSONSerialization.data(withJSONObject: legacyObject)
        let legacyStatus = try! CompanionJSON.decoder.decode(
            CompanionMacStatus.self,
            from: legacyData
        )
        expect(legacyStatus.agents == nil, "decodes status written by an older Mac build")
        expect(
            legacyStatus.operatorSummary == nil,
            "decodes status written before Operator summaries existed"
        )
        expect(
            legacyStatus.remoteWork == nil,
            "decodes status written before Remote Work sharing existed"
        )

        let projectedStatus = status.applyingKeepAwake(parameters: ["enabled": "false"])
        expect(
            !projectedStatus.automaticAgentAwakeEnabled,
            "projects an automatic agent-awake toggle while its command is pending"
        )
        expect(
            projectedStatus.keepDisplayAwake == status.keepDisplayAwake,
            "keeps unrelated awake settings unchanged in a local projection"
        )
        expect(
            projectedStatus.awakeMode == status.awakeMode,
            "keeps the awake mode unchanged when it was not requested"
        )

        let temperatureSensors = CompanionTemperatureParser.sensors(from: """
        cpu-sensors=Tp01=57.5,Tp05=unavailable
        gpu-sensors=Tg0K=48.0
        auxiliary-sensors=Tm0p=43.25
        """)
        expect(temperatureSensors.count == 3, "parses available detailed temperature readings")
        expect(
            temperatureSensors.first(where: { $0.key == "Tp01" })?.celsius == 57.5,
            "preserves precise sensor temperatures"
        )
        expect(
            !temperatureSensors.contains(where: { $0.key == "Tp05" }),
            "omits unavailable sensor readings"
        )

        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.startOfDay(for: now)
        let historySnapshot = InsightsSnapshot(
            energy: [],
            buckets: [
                EnergyBucket(
                    bucketStart: day.addingTimeInterval(60 * 60),
                    durationSeconds: 300,
                    averageWatts: 100,
                    peakWatts: 140,
                    kilowattHours: 0.5,
                    source: .ac,
                    confidence: .estimated,
                    sampleCount: 5
                ),
                EnergyBucket(
                    bucketStart: day.addingTimeInterval(2 * 60 * 60),
                    durationSeconds: 300,
                    averageWatts: 80,
                    peakWatts: 90,
                    kilowattHours: 0.4,
                    source: .ac,
                    confidence: .estimated,
                    sampleCount: 4
                )
            ],
            activities: [
                AgentActivityInterval(
                    id: UUID(),
                    agentID: "codex",
                    agentName: "Codex",
                    startedAt: day.addingTimeInterval(23 * 60 * 60),
                    endedAt: day.addingTimeInterval(26 * 60 * 60),
                    state: .finished,
                    peakSessionCount: 2
                )
            ],
            updatedAt: now,
            historyEnabled: true,
            storageBytes: 12_345
        )
        let history = CompanionHistoryBuilder.make(
            deviceID: "mac-1",
            snapshot: historySnapshot,
            now: day.addingTimeInterval(36 * 60 * 60),
            calendar: calendar
        )
        expect(history.energyDays.count == 1, "aggregates energy into a day summary")
        expect(
            abs((history.energyDays.first?.kilowattHours ?? 0) - 0.9) < 0.0001,
            "preserves daily kWh"
        )
        expect(history.agentDays.count == 2, "splits overnight agent activity across days")
        expect(
            history.agentDays.reduce(0) { $0 + $1.activeSeconds } == 3 * 60 * 60,
            "preserves total agent activity duration"
        )
        expect(history.agentTypeDays?.count == 2, "publishes a day-level total for each agent type")
        expect(
            history.agentTypeDays?.reduce(0) { $0 + $1.activeSeconds } == 3 * 60 * 60,
            "preserves typed agent activity duration"
        )
    }

    private static func testSelectsFreshReplacementForStalePersistedMac() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = selectionStatus(
            deviceID: "old-device",
            lastSeen: now.addingTimeInterval(-7 * 24 * 60 * 60)
        )
        let fresh = selectionStatus(
            deviceID: "replacement-device",
            lastSeen: now.addingTimeInterval(-2)
        )

        let selected = CompanionMacSelection.preferred(
            from: [stale, fresh],
            persistedDeviceID: stale.deviceID,
            now: now
        )
        expect(
            selected?.deviceID == fresh.deviceID,
            "replaces a stale persisted Mac identity with its fresh same-name record"
        )
    }

    private static func testDoesNotSwitchAStaleSelectionToAnotherMac() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let selected = selectionStatus(
            deviceID: "selected-device",
            displayName: "Studio Mac",
            lastSeen: now.addingTimeInterval(-7 * 24 * 60 * 60)
        )
        let unrelated = selectionStatus(
            deviceID: "other-device",
            displayName: "Travel Mac",
            lastSeen: now.addingTimeInterval(-2)
        )

        let result = CompanionMacSelection.preferred(
            from: [selected, unrelated],
            persistedDeviceID: selected.deviceID,
            now: now
        )
        expect(
            result?.deviceID == selected.deviceID,
            "does not silently retarget remote controls to a different Mac"
        )
    }

    private static func selectionStatus(
        deviceID: String,
        displayName: String = "Manto MBP",
        lastSeen: Date
    ) -> CompanionMacStatus {
        CompanionMacStatus(
            deviceID: deviceID,
            displayName: displayName,
            build: "2.3.1 (18)",
            lastSeen: lastSeen,
            uptimeSeconds: 100,
            powerSource: .ac,
            batteryPercent: 80,
            thermalState: "nominal",
            activeAgentCount: 0,
            activeSessionCount: 0,
            awakeMode: "preventSleep",
            displayAsleep: false,
            isKeepingAwake: false,
            keepDisplayAwake: true,
            automaticAgentAwakeEnabled: true,
            wakeDisplayWhenAgentsFinish: false,
            estimatedWatts: 10,
            energySource: .ac,
            energyConfidence: .estimated,
            isCharging: true,
            capabilities: CompanionMacCapabilities(supportsCloudKit: true)
        )
    }

    private static func testPreciseElapsedTimeText() {
        let now = Date(timeIntervalSince1970: 200_000)
        expect(
            CompanionTimeText.elapsed(
                since: now.addingTimeInterval(-(43 * 60 * 60)),
                now: now
            ) == "1d 19h ago",
            "does not round a partial second day up to two days"
        )
        expect(
            CompanionTimeText.elapsed(
                since: now.addingTimeInterval(-(12 * 60 + 8)),
                now: now
            ) == "12m ago",
            "shows concise minute precision for recent updates"
        )
    }

    private static func testCommandProgressStages() {
        let commandID = UUID()
        let sending = CompanionCommandProgress(
            commandID: commandID,
            actionTitle: "Prevent Sleep",
            stage: .sending
        )
        let waiting = sending.withStage(.waitingForMac)
        let completed = waiting.withStage(.completed)

        expect(sending.fraction < waiting.fraction, "advances progress while waiting for the Mac")
        expect(waiting.fraction < completed.fraction, "finishes progress after confirmation")
        expect(completed.isTerminal, "marks completed command progress as terminal")
        expect(completed.statusText == "Done", "uses a concise completed status")
    }

    private static func testContextTransferHistoryKeepsLatestState() {
        let suiteName = "CompanionContextTransferHistory-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Test failed: creates isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CompanionContextTransferHistoryStore(
            defaults: defaults,
            storageKey: "history",
            maximumItems: 2
        )
        let transferID = UUID()
        _ = store.record(CompanionContextTransferActivity(
            transferID: transferID,
            targetDeviceID: "mac-1",
            targetDisplayName: "Studio Mac",
            filename: "brief.pdf",
            byteCount: 1_024,
            updatedAt: Date(timeIntervalSince1970: 10),
            state: .sending
        ))
        let recorded = store.record(CompanionContextTransferActivity(
            transferID: transferID,
            targetDeviceID: "mac-1",
            targetDisplayName: "Studio Mac",
            filename: "brief.pdf",
            byteCount: 1_024,
            updatedAt: Date(timeIntervalSince1970: 20),
            state: .delivered
        ))
        _ = store.record(CompanionContextTransferActivity(
            transferID: UUID(),
            targetDeviceID: "mac-2",
            targetDisplayName: "Travel Mac",
            filename: "todo.txt",
            byteCount: 512,
            updatedAt: Date(timeIntervalSince1970: 30),
            state: .pending
        ))
        _ = store.record(CompanionContextTransferActivity(
            transferID: UUID(),
            targetDeviceID: "mac-3",
            targetDisplayName: "Lab Mac",
            filename: "notes.md",
            byteCount: 256,
            updatedAt: Date(timeIntervalSince1970: 40),
            state: .failed
        ))

        expect(recorded.count == 1, "replaces an existing transfer entry instead of duplicating it")
        expect(store.items.count == 2, "trims transfer history to the configured maximum")
        expect(store.items.last?.transferID != transferID, "drops the oldest history item when trimming")
        expect(
            CompanionContextTransferActivityState.delivered.title == "Delivered",
            "exposes concise transfer state labels"
        )
    }

    private static func testContextTransferHistoryFiltersByDevice() {
        let suiteName = "CompanionContextTransferHistoryFilter-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Test failed: creates isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CompanionContextTransferHistoryStore(
            defaults: defaults,
            storageKey: "history",
            maximumItems: 8
        )
        _ = store.record(CompanionContextTransferActivity(
            transferID: UUID(),
            targetDeviceID: "mac-1",
            targetDisplayName: "Studio Mac",
            filename: "alpha.txt",
            byteCount: 120,
            updatedAt: Date(timeIntervalSince1970: 10),
            state: .delivered
        ))
        _ = store.record(CompanionContextTransferActivity(
            transferID: UUID(),
            targetDeviceID: "mac-2",
            targetDisplayName: "Travel Mac",
            filename: "beta.txt",
            byteCount: 220,
            updatedAt: Date(timeIntervalSince1970: 20),
            state: .failed
        ))
        _ = store.record(CompanionContextTransferActivity(
            transferID: UUID(),
            targetDeviceID: "mac-1",
            targetDisplayName: "Studio Mac",
            filename: "gamma.txt",
            byteCount: 320,
            updatedAt: Date(timeIntervalSince1970: 30),
            state: .waitingForMac
        ))

        let filtered = store.recentItems(for: "mac-1", limit: 5)

        expect(filtered.map(\.filename) == ["gamma.txt", "alpha.txt"], "returns recent items only for the chosen Mac")
    }

    private static func testWidgetRefreshPlan() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let studio = CompanionWidgetSnapshot(
            deviceID: "studio-mac",
            macName: "Studio Mac",
            batteryPercent: 84,
            temperatureCelsius: 48,
            fanRPM: 1_800,
            isCharging: true,
            activeSessionCount: 2,
            thermalState: "nominal",
            updatedAt: now.addingTimeInterval(-45)
        )
        let travel = CompanionWidgetSnapshot(
            deviceID: "travel-mac",
            macName: "Travel Mac",
            batteryPercent: 52,
            temperatureCelsius: 61,
            fanRPM: 2_800,
            isCharging: false,
            activeSessionCount: 0,
            thermalState: "fair",
            updatedAt: now.addingTimeInterval(-7 * 60)
        )

        let configured = CompanionWidgetRefreshPlan.make(
            snapshots: [studio, travel],
            configuredDeviceID: "travel-mac",
            defaultDeviceID: "studio-mac",
            now: now
        )
        expect(
            configured.snapshot?.deviceID == "travel-mac",
            "uses the Mac chosen in Edit Widget instead of silently falling back"
        )
        expect(
            configured.freshness == .stale,
            "marks an old Mac reading as stale"
        )
        expect(
            configured.freshnessLabel == "Mac last reported 7m ago",
            "labels stale widget data as a Mac report, not a phone refresh"
        )

        let defaulted = CompanionWidgetRefreshPlan.make(
            snapshots: [travel, studio],
            configuredDeviceID: nil,
            defaultDeviceID: "studio-mac",
            now: now
        )
        expect(
            defaulted.snapshot?.deviceID == "studio-mac",
            "uses the companion's selected Mac when Edit Widget has no choice"
        )
        expect(defaulted.freshness == .reporting, "recognizes a current Mac report")
        expect(defaulted.freshnessLabel == "Mac reporting", "uses a calm current-data label")
        expect(
            defaulted.nextRefreshAt == now.addingTimeInterval(15 * 60),
            "uses a documented fifteen-minute WidgetKit fallback refresh"
        )

        let missingChoice = CompanionWidgetRefreshPlan.make(
            snapshots: [studio],
            configuredDeviceID: "removed-mac",
            defaultDeviceID: "studio-mac",
            now: now
        )
        expect(
            missingChoice.snapshot == nil,
            "does not replace a removed chosen Mac with a different computer"
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError("Test failed: \(message)")
        }
    }

    private static func isSuccess(
        _ result: Result<Void, CompanionCommandValidationError>
    ) -> Bool {
        if case .success = result { return true }
        return false
    }

    private static func isFailure(
        _ result: Result<Void, CompanionCommandValidationError>,
        _ expected: CompanionCommandValidationError
    ) -> Bool {
        guard case .failure(let error) = result else { return false }
        return error == expected
    }
}
