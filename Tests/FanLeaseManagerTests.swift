import Foundation

enum FanLeaseManagerTests {
    static func run() {
        testUnqualifiedHardwareNeverWrites()
        testLeaseLifecycle()
        testExpiryRestores()
        testDisconnectSleepAndWakeRestore()
        testFailureRestores()
        testTelemetryFailureRestoresImmediately()
        testStartupRestoreLatch()
        testWatchdogRetriesFailedRestore()
        testRestoreRetryPausesForExternalController()
        testProfileChangeRequiresVerifiedRestore()
        testSingleOwnerAndConflict()
        testSystemPowerEventRouting()
        testUnverifiedSystemControlIsNotReportedAsSafe()
    }

    private static func testUnqualifiedHardwareNeverWrites() {
        let backend = FakeFanHardware(qualification: .monitoringOnly)
        let manager = FanLeaseManager(backend: backend)
        let response = manager.beginLease(
            connectionID: UUID(),
            profileRawValue: FanHelperRequestedProfile.maximum.rawValue
        )

        expect(!response.succeeded, "rejects unqualified maximum cooling")
        expect(
            response.errorCode == .unqualifiedHardware,
            "reports unqualified hardware"
        )
        expect(backend.appliedDemands.isEmpty, "does not write unqualified hardware")
    }

    private static func testLeaseLifecycle() {
        var time = Date(timeIntervalSince1970: 1_000)
        let backend = FakeFanHardware(qualification: .adaptiveQualified)
        let manager = FanLeaseManager(
            backend: backend,
            now: { time }
        )
        let connectionID = UUID()
        let begin = manager.beginLease(
            connectionID: connectionID,
            profileRawValue: FanHelperRequestedProfile.aggressive.rawValue
        )

        expect(begin.succeeded, "starts a qualified cooling lease")
        expect(begin.leaseToken != nil, "returns an opaque lease token")
        expect(
            manager.status().leaseToken == nil,
            "does not disclose a lease token without its owning connection"
        )
        expect(
            manager.status(connectionID: connectionID).leaseToken
                == begin.leaseToken,
            "returns the lease token only to its owning connection"
        )
        expect(backend.markerIsActive, "persists a crash-recovery marker")
        expect(backend.appliedDemands == [0.5], "starts adaptive cooling at its floor")

        time.addTimeInterval(3)
        let renew = manager.renewLease(
            connectionID: connectionID,
            leaseToken: begin.leaseToken!,
            coolingDemand: 0.8
        )
        expect(renew.succeeded, "renews the active lease")
        expect(backend.appliedDemands == [0.5, 0.8], "applies normalized demand")

        let end = manager.endLease(
            connectionID: connectionID,
            leaseToken: begin.leaseToken!
        )
        expect(end.succeeded, "ends the active lease")
        expect(backend.restoreCount == 1, "restores macOS exactly once")
        expect(!backend.markerIsActive, "clears the recovery marker after restore")
        expect(end.snapshot.systemControlVerified, "reports verified system control")
    }

    private static func testExpiryRestores() {
        var time = Date(timeIntervalSince1970: 2_000)
        let backend = FakeFanHardware(qualification: .maximumQualified)
        let manager = FanLeaseManager(
            backend: backend,
            leaseDuration: 10,
            now: { time }
        )
        let connectionID = UUID()
        let begin = manager.beginLease(
            connectionID: connectionID,
            profileRawValue: FanHelperRequestedProfile.maximum.rawValue
        )
        expect(begin.succeeded, "starts maximum cooling")
        expect(backend.appliedDemands == [1], "forces maximum demand")

        time.addTimeInterval(11)
        manager.expireIfNeeded()
        expect(backend.restoreCount == 1, "restores when the ten-second lease expires")
        expect(
            manager.status().snapshot.state == .systemControl,
            "invalidates the expired lease"
        )
    }

    private static func testDisconnectSleepAndWakeRestore() {
        let backend = FakeFanHardware(qualification: .maximumQualified)
        let manager = FanLeaseManager(backend: backend)
        let owner = UUID()
        let other = UUID()
        _ = manager.beginLease(
            connectionID: owner,
            profileRawValue: FanHelperRequestedProfile.maximum.rawValue
        )
        manager.connectionEnded(other)
        expect(backend.restoreCount == 0, "ignores unrelated disconnects")
        manager.connectionEnded(owner)
        expect(backend.restoreCount == 1, "restores on owner disconnect")

        _ = manager.beginLease(
            connectionID: owner,
            profileRawValue: FanHelperRequestedProfile.maximum.rawValue
        )
        manager.systemWillSleep()
        expect(backend.restoreCount == 2, "restores before system sleep")

        _ = manager.beginLease(
            connectionID: owner,
            profileRawValue: FanHelperRequestedProfile.maximum.rawValue
        )
        manager.systemDidWake()
        expect(backend.restoreCount == 3, "restores and invalidates on wake")
    }

    private static func testFailureRestores() {
        let backend = FakeFanHardware(qualification: .maximumQualified)
        backend.applyError = .verificationFailed
        let manager = FanLeaseManager(backend: backend)
        let response = manager.beginLease(
            connectionID: UUID(),
            profileRawValue: FanHelperRequestedProfile.maximum.rawValue
        )

        expect(!response.succeeded, "reports a failed hardware verification")
        expect(backend.restoreCount == 1, "actively restores after an apply failure")
        expect(!backend.markerIsActive, "clears the marker after successful recovery")

        backend.applyError = .verificationFailed
        backend.restoreError = .restoreFailed
        let unrecovered = manager.beginLease(
            connectionID: UUID(),
            profileRawValue: FanHelperRequestedProfile.maximum.rawValue
        )
        expect(
            unrecovered.snapshot.state == .restoreFailed,
            "does not claim safe restoration when verification fails"
        )
    }

    private static func testSingleOwnerAndConflict() {
        let backend = FakeFanHardware(qualification: .adaptiveQualified)
        let manager = FanLeaseManager(backend: backend)
        let owner = UUID()
        let begin = manager.beginLease(
            connectionID: owner,
            profileRawValue: FanHelperRequestedProfile.aggressive.rawValue
        )
        let second = manager.beginLease(
            connectionID: UUID(),
            profileRawValue: FanHelperRequestedProfile.maximum.rawValue
        )
        expect(
            second.errorCode == .leaseOwnedByAnotherConnection,
            "allows only one authenticated owner"
        )

        let invalidDemand = manager.renewLease(
            connectionID: owner,
            leaseToken: begin.leaseToken!,
            coolingDemand: .infinity
        )
        expect(
            invalidDemand.errorCode == .invalidRequest,
            "rejects non-finite demand"
        )

        backend.externalControllerRunning = true
        let conflict = manager.renewLease(
            connectionID: owner,
            leaseToken: begin.leaseToken!,
            coolingDemand: 1
        )
        expect(
            conflict.errorCode == .externalControllerConflict,
            "stops when another controller appears"
        )
        expect(backend.restoreCount == 1, "restores before reporting a conflict")
    }

    private static func testTelemetryFailureRestoresImmediately() {
        let backend = FakeFanHardware(
            qualification: .maximumQualified
        )
        backend.snapshotError = .invalidTelemetry
        let manager = FanLeaseManager(backend: backend)
        let response = manager.beginLease(
            connectionID: UUID(),
            profileRawValue: FanHelperRequestedProfile.maximum.rawValue
        )

        expect(
            response.errorCode == .telemetryFailed,
            "reports failed telemetry after a cooling write"
        )
        expect(
            backend.restoreCount == 1,
            "restores immediately when post-write telemetry disappears"
        )
        expect(
            !backend.markerIsActive,
            "clears the recovery marker after telemetry-failure restoration"
        )
        expect(
            response.snapshot.state == .systemControl
                && response.snapshot.systemControlVerified,
            "does not leave a stale cooling state after telemetry failure"
        )

        let unrecoveredBackend = FakeFanHardware(
            qualification: .maximumQualified
        )
        unrecoveredBackend.snapshotError = .invalidTelemetry
        unrecoveredBackend.restoreError = .restoreFailed
        let unrecoveredManager = FanLeaseManager(
            backend: unrecoveredBackend
        )
        let unrecovered = unrecoveredManager.beginLease(
            connectionID: UUID(),
            profileRawValue: FanHelperRequestedProfile.maximum.rawValue
        )
        expect(
            unrecovered.errorCode == .restoreFailed
                && unrecovered.snapshot.state == .restoreFailed,
            "latches restoration failure after cooling telemetry is lost"
        )
    }

    private static func testStartupRestoreLatch() {
        let backend = FakeFanHardware(qualification: .maximumQualified)
        backend.markerIsActive = true
        backend.restoreError = .restoreFailed
        let manager = FanLeaseManager(backend: backend)

        let recovery = manager.recoverOnStartup()
        expect(
            recovery.errorCode == .restoreFailed
                && recovery.snapshot.state == .restoreFailed,
            "latches a failed startup restoration"
        )

        let blocked = manager.beginLease(
            connectionID: UUID(),
            profileRawValue: FanHelperRequestedProfile.maximum.rawValue
        )
        expect(
            blocked.errorCode == .restoreFailed,
            "refuses new writes while startup restoration is unresolved"
        )
        expect(
            backend.appliedDemands.isEmpty,
            "does not write after a failed startup restoration"
        )

        backend.restoreError = nil
        let repaired = manager.restoreSystemControl()
        expect(repaired.succeeded, "allows an explicit restoration retry")
        let begin = manager.beginLease(
            connectionID: UUID(),
            profileRawValue: FanHelperRequestedProfile.maximum.rawValue
        )
        expect(
            begin.succeeded,
            "unlocks cooling only after restoration is verified"
        )
    }

    private static func testSystemPowerEventRouting() {
        expect(
            SystemPowerObserver.event(
                for: SystemPowerObserver.canSystemSleepMessage
            ) == .allowIdleSleep,
            "acknowledges idle-sleep checks without changing fan state"
        )
        expect(
            SystemPowerObserver.event(
                for: SystemPowerObserver.systemWillSleepMessage
            ) == .willSleep,
            "routes the non-abortable sleep event through restoration"
        )
        expect(
            SystemPowerObserver.event(
                for: SystemPowerObserver.systemHasPoweredOnMessage
            ) == .didWake,
            "routes completed wake through restoration"
        )
        expect(
            SystemPowerObserver.event(for: 0) == .ignore,
            "ignores unrelated root-power-domain messages"
        )
    }

    private static func testUnverifiedSystemControlIsNotReportedAsSafe() {
        let backend = FakeFanHardware(
            qualification: .maximumQualified
        )
        backend.systemControlVerifiedOverride = false
        let response = FanLeaseManager(backend: backend).status()
        expect(
            !response.succeeded
                && response.errorCode == .externalControllerConflict,
            "does not report System Control when fan modes are still manual"
        )
        expect(
            response.snapshot.state == .externalControllerConflict,
            "publishes the verified manual-control conflict"
        )
    }

    private static func testProfileChangeRequiresVerifiedRestore() {
        let backend = FakeFanHardware(qualification: .adaptiveQualified)
        let manager = FanLeaseManager(backend: backend)
        let owner = UUID()
        let first = manager.beginLease(
            connectionID: owner,
            profileRawValue: FanHelperRequestedProfile.aggressive.rawValue
        )
        expect(first.succeeded, "starts the first profile")

        backend.restoreError = .restoreFailed
        let changed = manager.beginLease(
            connectionID: owner,
            profileRawValue: FanHelperRequestedProfile.maximum.rawValue
        )
        expect(
            changed.errorCode == .restoreFailed,
            "does not apply a new profile after restoration fails"
        )
        expect(
            backend.appliedDemands == [0.5],
            "performs no second write after failed profile-change restoration"
        )
    }

    private static func testWatchdogRetriesFailedRestore() {
        let backend = FakeFanHardware(
            qualification: .maximumQualified
        )
        backend.markerIsActive = true
        backend.restoreError = .restoreFailed
        let manager = FanLeaseManager(backend: backend)
        let firstAttempt = manager.recoverOnStartup()
        expect(
            firstAttempt.errorCode == .restoreFailed,
            "records the first failed restoration"
        )

        backend.restoreError = nil
        manager.expireIfNeeded()
        let recovered = manager.status()
        expect(
            recovered.succeeded
                && recovered.snapshot.state == .systemControl,
            "watchdog maintenance retries restoration until it succeeds"
        )
        expect(
            !backend.markerIsActive,
            "clears the recovery marker after watchdog restoration"
        )
    }

    private static func testRestoreRetryPausesForExternalController() {
        let backend = FakeFanHardware(
            qualification: .maximumQualified
        )
        backend.markerIsActive = true
        backend.restoreError = .restoreFailed
        let manager = FanLeaseManager(backend: backend)
        _ = manager.recoverOnStartup()
        let attemptsAfterFailure = backend.restoreCount

        backend.restoreError = nil
        backend.externalControllerRunning = true
        manager.expireIfNeeded()
        expect(
            backend.restoreCount == attemptsAfterFailure,
            "does not fight another active fan controller during retry"
        )

        backend.externalControllerRunning = false
        manager.expireIfNeeded()
        expect(
            backend.restoreCount == attemptsAfterFailure + 1
                && !backend.markerIsActive,
            "resumes restoration after the external controller exits"
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

private final class FakeFanHardware: FanHardwareControlling {
    let model = "Mac16,7"
    let qualification: FanControlQualification
    var externalControllerRunning = false
    var markerIsActive = false
    var appliedDemands: [Double] = []
    var restoreCount = 0
    var applyError: FanHardwareError?
    var restoreError: FanHardwareError?
    var snapshotError: FanHardwareError?
    var systemControlVerifiedOverride: Bool?

    init(qualification: FanControlQualification) {
        self.qualification = qualification
    }

    func externalControllerIsRunning() -> Bool {
        externalControllerRunning
    }

    func hasRecoveryMarker() -> Bool {
        markerIsActive
    }

    func setRecoveryMarker(active: Bool) throws {
        markerIsActive = active
    }

    func snapshot(
        state: FanHelperState,
        verifiedDemand: Double?,
        leaseExpiresAt: Date?,
        detail: String?
    ) throws -> FanHelperSnapshot {
        if let snapshotError {
            throw snapshotError
        }
        return FanHelperSnapshot(
            model: model,
            state: state,
            qualification: qualification,
            aggregateTemperatureCelsius: 55,
            temperatureRecordedAt: Date(),
            fans: [
                FanTelemetryMessage(
                    index: 0,
                    actualRPM: 4_000,
                    minimumRPM: 1_500,
                    maximumRPM: 6_000,
                    targetRPM: verifiedDemand.map {
                        1_500 + $0 * 4_500
                    },
                    mode: state == .cooling ? 1 : 0
                )
            ],
            verifiedDemand: verifiedDemand,
            systemControlVerified:
                systemControlVerifiedOverride ?? (state == .systemControl),
            leaseExpiresAt: leaseExpiresAt,
            detail: detail
        )
    }

    func applyCoolingDemand(_ demand: Double) throws {
        if let applyError {
            throw applyError
        }
        appliedDemands.append(demand)
    }

    func restoreSystemControl() throws {
        restoreCount += 1
        if let restoreError {
            throw restoreError
        }
    }
}
