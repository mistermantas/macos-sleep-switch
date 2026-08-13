import Foundation

enum CompanionProtocolTests {
    static func run() {
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

        var legacyObject = try! JSONSerialization.jsonObject(with: encodedStatus) as! [String: Any]
        legacyObject.removeValue(forKey: "agents")
        legacyObject.removeValue(forKey: "manualSession")
        legacyObject.removeValue(forKey: "cooling")
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
