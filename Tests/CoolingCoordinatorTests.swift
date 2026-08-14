#if !APP_STORE
import Foundation

enum CoolingCoordinatorTests {
    static func run() {
        let suite = "SleepSwitch.CoolingCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let client = FakeFanHelperClient()
        let coordinator = CoolingCoordinator(
            client: client,
            defaults: defaults
        )

        coordinator.selectProfile(.maximum)
        coordinator.updateControlEnabled(false)
        expect(client.beginProfiles.isEmpty, "does not cool while control is disabled")

        coordinator.updateControlEnabled(true)
        expect(
            client.beginProfiles == [.maximum],
            "starts maximum cooling when control is enabled"
        )
        expect(coordinator.presentation.hasActiveLease, "tracks the helper lease")
        expect(
            coordinator.presentation.effectiveTitle == "Maximum",
            "shows a selected profile only after the helper verifies its lease"
        )

        coordinator.heartbeat(
            now: Date(timeIntervalSince1970: 105)
        )
        expect(client.renewDemands == [1], "renews maximum demand every heartbeat")

        coordinator.updateControlEnabled(false)
        expect(client.endTokens.count == 1, "ends cooling when control is disabled")
        expect(!coordinator.presentation.hasActiveLease, "clears the ended lease")
        expect(
            coordinator.presentation.effectiveTitle == "System Control",
            "shows the restored effective state after the awake session"
        )

        var thermalAbort: CoolingAbortReason?
        coordinator.onThermalAbort = { thermalAbort = $0 }
        coordinator.updateControlEnabled(true)
        client.nextSnapshot = client.snapshot(
            temperature: nil,
            leaseToken: client.leaseToken
        ).snapshot
        coordinator.heartbeat(
            now: Date(timeIntervalSince1970: 105)
        )
        coordinator.heartbeat(
            now: Date(timeIntervalSince1970: 108)
        )
        expect(
            thermalAbort == .missingTemperature,
            "ends the owned awake path when cooling telemetry disappears"
        )

        coordinator.selectProfile(.systemControl)
        expect(
            defaults.string(forKey: CoolingCoordinator.profileDefaultsKey)
                == CoolingProfile.systemControl.rawValue,
            "persists System Control as an explicit safe profile"
        )

        testFailedLeaseDoesNotRetry()
        testFailedRenewalDoesNotRestartLease()
        testFailedProfileRestoreDoesNotStartReplacementLease()
        testSustainedHighTemperatureEndsLease()
    }

    private static func testFailedLeaseDoesNotRetry() {
        let suite = "SleepSwitch.CoolingBlockedTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = FakeFanHelperClient()
        client.qualification = .monitoringOnly
        client.beginSucceeds = false
        let coordinator = CoolingCoordinator(
            client: client,
            defaults: defaults
        )

        coordinator.selectProfile(.maximum)
        coordinator.updateControlEnabled(true)
        expect(
            client.beginProfiles == [.maximum],
            "asks the helper once before qualification is known"
        )
        coordinator.heartbeat()
        coordinator.heartbeat()
        expect(
            client.beginProfiles == [.maximum],
            "does not retry-loop a rejected lease"
        )

        coordinator.refreshStatus()
        expect(
            client.beginProfiles == [.maximum],
            "uses monitoring-only status to avoid another rejected write"
        )
    }

    private static func testFailedRenewalDoesNotRestartLease() {
        let suite = "SleepSwitch.CoolingRenewalTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = FakeFanHelperClient()
        let coordinator = CoolingCoordinator(
            client: client,
            defaults: defaults
        )

        coordinator.selectProfile(.maximum)
        coordinator.updateControlEnabled(true)
        client.renewSucceeds = false
        coordinator.heartbeat(
            now: Date(timeIntervalSince1970: 105)
        )
        coordinator.heartbeat(
            now: Date(timeIntervalSince1970: 108)
        )
        expect(
            client.beginProfiles == [.maximum],
            "does not restart a lease after renewal verification fails"
        )
    }

    private static func testSustainedHighTemperatureEndsLease() {
        let suite = "SleepSwitch.CoolingHeatAbortTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = FakeFanHelperClient()
        client.beginTemperature = CoolingPolicy.abortCeilingCelsius
        let coordinator = CoolingCoordinator(
            client: client,
            defaults: defaults
        )
        var abortReason: CoolingAbortReason?
        coordinator.onThermalAbort = { abortReason = $0 }

        coordinator.selectProfile(.maximum)
        coordinator.updateControlEnabled(true)
        let firstHotHeartbeat = 105.0
        let abortHeartbeat =
            firstHotHeartbeat + CoolingPolicy.abortCeilingGrace
        var heartbeat = firstHotHeartbeat
        while heartbeat <= abortHeartbeat {
            client.nextSnapshot = client.snapshot(
                temperature: CoolingPolicy.abortCeilingCelsius,
                leaseToken: client.leaseToken,
                recordedAt: Date(timeIntervalSince1970: heartbeat)
            ).snapshot
            coordinator.heartbeat(
                now: Date(timeIntervalSince1970: heartbeat)
            )
            heartbeat += FanHelperConstants.heartbeatInterval
        }

        expect(
            abortReason == .sustainedHighTemperature,
            "ends cooling after the maximum-cooling heat ceiling persists"
        )
        expect(
            client.endTokens.count == 1,
            "releases the helper lease after a sustained heat abort"
        )
        expect(
            !coordinator.presentation.hasActiveLease,
            "clears the local lease after a sustained heat abort"
        )
    }

    private static func testFailedProfileRestoreDoesNotStartReplacementLease() {
        let suite =
            "SleepSwitch.CoolingProfileRestoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = FakeFanHelperClient()
        let coordinator = CoolingCoordinator(
            client: client,
            defaults: defaults
        )

        coordinator.selectProfile(.aggressive)
        coordinator.updateControlEnabled(true)
        client.endSucceeds = false
        coordinator.selectProfile(.maximum)

        expect(
            client.beginProfiles == [.aggressive],
            "does not write a replacement profile after restoration fails"
        )
        expect(
            !coordinator.presentation.hasActiveLease,
            "drops the local lease after failed profile restoration"
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
}

private final class FakeFanHelperClient: FanHelperClienting {
    var registrationState: FanHelperRegistrationState = .enabled
    let leaseToken = UUID()
    var beginProfiles: [FanHelperRequestedProfile] = []
    var renewDemands: [Double] = []
    var endTokens: [UUID] = []
    var nextSnapshot: FanHelperSnapshot?
    var qualification: FanControlQualification = .maximumQualified
    var beginSucceeds = true
    var renewSucceeds = true
    var endSucceeds = true
    var beginTemperature: Double? = 55

    func status(_ completion: @escaping (FanHelperResponse) -> Void) {
        completion(snapshot(temperature: 55, leaseToken: nil))
    }

    func beginLease(
        profile: FanHelperRequestedProfile,
        completion: @escaping (FanHelperResponse) -> Void
    ) {
        beginProfiles.append(profile)
        if beginSucceeds {
            completion(
                snapshot(
                    temperature: beginTemperature,
                    leaseToken: leaseToken
                )
            )
        } else {
            completion(
                failure(
                    code: .unqualifiedHardware,
                    message: "Cooling control is not qualified for this Mac."
                )
            )
        }
    }

    func renewLease(
        token: UUID,
        demand: Double,
        completion: @escaping (FanHelperResponse) -> Void
    ) {
        renewDemands.append(demand)
        guard renewSucceeds else {
            completion(
                failure(
                    code: .applyFailed,
                    message: "Cooling verification failed."
                )
            )
            return
        }
        completion(
            FanHelperResponse(
                succeeded: true,
                errorCode: .none,
                leaseToken: token,
                snapshot: nextSnapshot
                    ?? snapshot(
                        temperature: 55,
                        leaseToken: token
                    ).snapshot,
                message: nil
            )
        )
        nextSnapshot = nil
    }

    func endLease(
        token: UUID,
        completion: @escaping (FanHelperResponse) -> Void
    ) {
        endTokens.append(token)
        if endSucceeds {
            completion(snapshot(temperature: 55, leaseToken: nil))
        } else {
            completion(
                failure(
                    code: .restoreFailed,
                    message: "Fan restoration could not be verified."
                )
            )
        }
    }

    func restoreSystemControl(
        _ completion: @escaping (FanHelperResponse) -> Void
    ) {
        completion(snapshot(temperature: 55, leaseToken: nil))
    }

    func snapshot(
        temperature: Double?,
        leaseToken: UUID?,
        recordedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> FanHelperResponse {
        FanHelperResponse(
            succeeded: true,
            errorCode: .none,
            leaseToken: leaseToken,
            snapshot: FanHelperSnapshot(
                model: "Mac16,7",
                state: leaseToken == nil ? .systemControl : .cooling,
                qualification: qualification,
                aggregateTemperatureCelsius: temperature,
                temperatureRecordedAt: recordedAt,
                fans: [
                    FanTelemetryMessage(
                        index: 0,
                        actualRPM: 5_900,
                        minimumRPM: 1_500,
                        maximumRPM: 6_000,
                        targetRPM: 6_000,
                        mode: leaseToken == nil ? 0 : 1
                    )
                ],
                verifiedDemand: leaseToken == nil ? nil : 1,
                systemControlVerified: leaseToken == nil,
                leaseExpiresAt: Date(timeIntervalSince1970: 110),
                detail: nil
            ),
            message: nil
        )
    }

    private func failure(
        code: FanHelperErrorCode,
        message: String
    ) -> FanHelperResponse {
        FanHelperResponse(
            succeeded: false,
            errorCode: code,
            leaseToken: nil,
            snapshot: FanHelperSnapshot(
                model: "Mac16,7",
                state: qualification == .monitoringOnly
                    ? .monitoringOnly
                    : .systemControl,
                qualification: qualification,
                aggregateTemperatureCelsius: 55,
                temperatureRecordedAt: Date(),
                fans: [],
                verifiedDemand: nil,
                systemControlVerified: true,
                leaseExpiresAt: nil,
                detail: message
            ),
            message: message
        )
    }
}
#endif
