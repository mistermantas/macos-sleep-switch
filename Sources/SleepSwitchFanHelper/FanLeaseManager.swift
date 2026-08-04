import Foundation

final class FanLeaseManager {
    private struct Lease {
        let token: UUID
        let connectionID: UUID
        let profile: FanHelperRequestedProfile
        var demand: Double
        var expiresAt: Date
    }

    private let backend: FanHardwareControlling
    private let now: () -> Date
    private let leaseDuration: TimeInterval
    private let queue = DispatchQueue(
        label: "lt.mantas.sleepswitch.fanhelper.lease"
    )
    private var lease: Lease?
    private var restorationRequired: Bool
    private var lastSnapshot: FanHelperSnapshot

    init(
        backend: FanHardwareControlling,
        leaseDuration: TimeInterval = FanHelperConstants.leaseDuration,
        now: @escaping () -> Date = Date.init
    ) {
        self.backend = backend
        self.leaseDuration = leaseDuration
        self.now = now
        restorationRequired = backend.hasRecoveryMarker()
        lastSnapshot = Self.fallbackSnapshot(
            backend: backend,
            state: backend.qualification == .monitoringOnly
                ? .monitoringOnly
                : .systemControl,
            detail: nil
        )
    }

    func recoverOnStartup() -> FanHelperResponse {
        queue.sync {
            guard restorationRequired else {
                return statusLocked()
            }
            return restoreLocked(
                reason: "Recovered macOS fan control after an interrupted lease."
            )
        }
    }

    func status(connectionID: UUID? = nil) -> FanHelperResponse {
        queue.sync {
            expireIfNeededLocked()
            return statusLocked(connectionID: connectionID)
        }
    }

    func beginLease(
        connectionID: UUID,
        profileRawValue: Int
    ) -> FanHelperResponse {
        queue.sync {
            expireIfNeededLocked()

            guard let profile = FanHelperRequestedProfile(
                rawValue: profileRawValue
            ) else {
                return failureLocked(
                    .invalidRequest,
                    "Sleep Switch sent an invalid cooling profile."
                )
            }
            if profile == .systemControl {
                return restoreLocked(reason: nil)
            }
            guard !restorationRequired || lease != nil else {
                return failureLocked(
                    .restoreFailed,
                    "Cooling is locked until macOS fan control is restored.",
                    state: .restoreFailed
                )
            }
            guard !backend.externalControllerIsRunning() else {
                return failureLocked(
                    .externalControllerConflict,
                    "Another fan controller is open."
                )
            }
            guard profileIsQualified(profile) else {
                return failureLocked(
                    .unqualifiedHardware,
                    "Cooling control is not qualified for this Mac."
                )
            }
            if let lease, lease.connectionID != connectionID {
                return failureLocked(
                    .leaseOwnedByAnotherConnection,
                    "Cooling is already controlled by another Sleep Switch connection."
                )
            }

            if lease != nil {
                let restoration = restoreLocked(reason: nil)
                guard restoration.succeeded else {
                    return restoration
                }
            }

            let token = UUID()
            let demand = profile == .maximum ? 1 : 0.5

            do {
                try backend.setRecoveryMarker(active: true)
                restorationRequired = true
                try backend.applyCoolingDemand(demand)
                let expiresAt = now().addingTimeInterval(leaseDuration)
                lease = Lease(
                    token: token,
                    connectionID: connectionID,
                    profile: profile,
                    demand: demand,
                    expiresAt: expiresAt
                )
                return successLocked(
                    leaseToken: token,
                    state: .cooling,
                    verifiedDemand: demand,
                    leaseExpiresAt: expiresAt,
                    detail: nil
                )
            } catch {
                return applyFailureLocked(error)
            }
        }
    }

    func renewLease(
        connectionID: UUID,
        leaseToken: UUID,
        coolingDemand: Double
    ) -> FanHelperResponse {
        queue.sync {
            expireIfNeededLocked()

            guard coolingDemand.isFinite,
                  (0...1).contains(coolingDemand)
            else {
                return failureLocked(
                    .invalidRequest,
                    "Cooling demand must be between zero and one."
                )
            }
            guard var lease,
                  lease.connectionID == connectionID,
                  lease.token == leaseToken
            else {
                return failureLocked(
                    .invalidLease,
                    "The cooling lease is no longer active."
                )
            }
            guard !backend.externalControllerIsRunning() else {
                _ = restoreLocked(
                    reason: "Another fan controller opened, so Sleep Switch restored macOS control."
                )
                return failureLocked(
                    .externalControllerConflict,
                    "Another fan controller is open."
                )
            }

            let demand = lease.profile == .maximum
                ? 1
                : max(0.5, coolingDemand)
            do {
                try backend.applyCoolingDemand(demand)
                lease.demand = demand
                lease.expiresAt = now().addingTimeInterval(leaseDuration)
                self.lease = lease
                return successLocked(
                    leaseToken: lease.token,
                    state: .cooling,
                    verifiedDemand: demand,
                    leaseExpiresAt: lease.expiresAt,
                    detail: nil
                )
            } catch {
                return applyFailureLocked(error)
            }
        }
    }

    func endLease(
        connectionID: UUID,
        leaseToken: UUID
    ) -> FanHelperResponse {
        queue.sync {
            expireIfNeededLocked()
            guard let lease,
                  lease.connectionID == connectionID,
                  lease.token == leaseToken
            else {
                return failureLocked(
                    .invalidLease,
                    "The cooling lease is no longer active."
                )
            }
            return restoreLocked(reason: nil)
        }
    }

    func restoreSystemControl() -> FanHelperResponse {
        queue.sync {
            restoreLocked(reason: nil)
        }
    }

    func connectionEnded(_ connectionID: UUID) {
        queue.sync {
            guard lease?.connectionID == connectionID else { return }
            _ = restoreLocked(
                reason: "The app connection ended, so macOS fan control was restored."
            )
        }
    }

    func expireIfNeeded() {
        queue.sync {
            expireIfNeededLocked()
        }
    }

    func systemDidWake() {
        queue.sync {
            _ = restoreLocked(
                reason: "Sleep Switch requires a new cooling lease after wake."
            )
        }
    }

    func systemWillSleep() {
        queue.sync {
            _ = restoreLocked(
                reason: "Sleep Switch restored macOS fan control before sleep."
            )
        }
    }

    func shutDown() {
        queue.sync {
            _ = restoreLocked(reason: nil)
        }
    }

    private func expireIfNeededLocked() {
        if let lease {
            guard now() >= lease.expiresAt else { return }
            _ = restoreLocked(
                reason:
                    "The cooling lease expired, so macOS fan control was restored."
            )
            return
        }

        if restorationRequired,
           !backend.externalControllerIsRunning() {
            _ = restoreLocked(
                reason:
                    "Sleep Switch retried restoration of macOS fan control."
            )
        }
    }

    private func statusLocked(
        connectionID: UUID? = nil
    ) -> FanHelperResponse {
        if lease == nil, restorationRequired {
            return failureLocked(
                .restoreFailed,
                "Cooling is locked until macOS fan control is restored.",
                state: .restoreFailed
            )
        }

        let state: FanHelperState
        if lease != nil {
            state = .cooling
        } else if backend.externalControllerIsRunning() {
            state = .externalControllerConflict
        } else if backend.qualification == .monitoringOnly {
            state = .monitoringOnly
        } else {
            state = .systemControl
        }

        return successLocked(
            leaseToken: lease?.connectionID == connectionID
                ? lease?.token
                : nil,
            state: state,
            verifiedDemand: lease?.demand,
            leaseExpiresAt: lease?.expiresAt,
            detail: nil
        )
    }

    private func restoreLocked(reason: String?) -> FanHelperResponse {
        lease = nil
        do {
            try backend.restoreSystemControl()
            try backend.setRecoveryMarker(active: false)
            restorationRequired = false
            return successLocked(
                leaseToken: nil,
                state: backend.qualification == .monitoringOnly
                    ? .monitoringOnly
                    : .systemControl,
                verifiedDemand: nil,
                leaseExpiresAt: nil,
                detail: reason
            )
        } catch {
            restorationRequired = true
            return failureLocked(
                .restoreFailed,
                "Sleep Switch could not verify that macOS regained fan control.",
                state: .restoreFailed,
                detail: reason
            )
        }
    }

    private func applyFailureLocked(_ error: Error) -> FanHelperResponse {
        lease = nil
        restorationRequired = true
        let restoreSucceeded: Bool
        do {
            try backend.restoreSystemControl()
            try backend.setRecoveryMarker(active: false)
            restorationRequired = false
            restoreSucceeded = true
        } catch {
            restoreSucceeded = false
        }

        return failureLocked(
            restoreSucceeded ? errorCode(for: error) : .restoreFailed,
            restoreSucceeded
                ? "Sleep Switch could not apply and verify cooling, so macOS control was restored."
                : "Cooling failed and Sleep Switch could not verify restoration.",
            state: restoreSucceeded
                ? (
                    backend.qualification == .monitoringOnly
                        ? .monitoringOnly
                        : .systemControl
                )
                : .restoreFailed,
            detail: nil
        )
    }

    private func successLocked(
        leaseToken: UUID?,
        state: FanHelperState,
        verifiedDemand: Double?,
        leaseExpiresAt: Date?,
        detail: String?
    ) -> FanHelperResponse {
        do {
            let snapshot = try backend.snapshot(
                state: state,
                verifiedDemand: verifiedDemand,
                leaseExpiresAt: leaseExpiresAt,
                detail: detail
            )
            if state == .systemControl,
               !snapshot.systemControlVerified {
                return failureLocked(
                    .externalControllerConflict,
                    "Fan control is already manual outside Sleep Switch.",
                    state: .externalControllerConflict,
                    detail: detail
                )
            }
            lastSnapshot = snapshot
            return FanHelperResponse(
                succeeded: true,
                errorCode: .none,
                leaseToken: leaseToken,
                snapshot: lastSnapshot,
                message: detail
            )
        } catch {
            if state == .cooling {
                return recoverFromCoolingTelemetryFailureLocked()
            }
            return failureLocked(
                .telemetryFailed,
                "Cooling telemetry is temporarily unavailable.",
                state: .unavailable,
                detail: detail
            )
        }
    }

    private func failureLocked(
        _ code: FanHelperErrorCode,
        _ message: String,
        state: FanHelperState = .unavailable,
        detail: String? = nil
    ) -> FanHelperResponse {
        if let snapshot = try? backend.snapshot(
            state: state,
            verifiedDemand: nil,
            leaseExpiresAt: nil,
            detail: detail ?? message
        ) {
            lastSnapshot = snapshot
        }
        return FanHelperResponse(
            succeeded: false,
            errorCode: code,
            leaseToken: nil,
            snapshot: lastSnapshot,
            message: message
        )
    }

    private func recoverFromCoolingTelemetryFailureLocked()
        -> FanHelperResponse {
        lease = nil
        restorationRequired = true

        let state: FanHelperState
        let code: FanHelperErrorCode
        let message: String
        do {
            try backend.restoreSystemControl()
            try backend.setRecoveryMarker(active: false)
            restorationRequired = false
            state = backend.qualification == .monitoringOnly
                ? .monitoringOnly
                : .systemControl
            code = .telemetryFailed
            message =
                "Cooling telemetry failed, so macOS fan control was restored."
        } catch {
            state = .restoreFailed
            code = .restoreFailed
            message =
                "Cooling telemetry failed and restoration could not be verified."
        }

        if let snapshot = try? backend.snapshot(
            state: state,
            verifiedDemand: nil,
            leaseExpiresAt: nil,
            detail: message
        ) {
            lastSnapshot = snapshot
        } else {
            lastSnapshot = Self.fallbackSnapshot(
                backend: backend,
                state: state,
                detail: message
            )
        }

        return FanHelperResponse(
            succeeded: false,
            errorCode: code,
            leaseToken: nil,
            snapshot: lastSnapshot,
            message: message
        )
    }

    private func profileIsQualified(
        _ profile: FanHelperRequestedProfile
    ) -> Bool {
        switch profile {
        case .systemControl:
            return true
        case .maximum:
            return backend.qualification.permitsMaximumControl
        case .aggressive:
            return backend.qualification.permitsAggressiveControl
        }
    }

    private func errorCode(for error: Error) -> FanHelperErrorCode {
        guard let error = error as? FanHardwareError else {
            return .applyFailed
        }
        switch error {
        case .unavailable:
            return .unavailable
        case .unsupportedHardware:
            return .unsupportedHardware
        case .unqualifiedHardware:
            return .unqualifiedHardware
        case .externalControllerConflict, .ownershipLost:
            return .externalControllerConflict
        case .invalidTelemetry:
            return .telemetryFailed
        case .writeFailed, .verificationFailed:
            return .applyFailed
        case .restoreFailed:
            return .restoreFailed
        }
    }

    private static func fallbackSnapshot(
        backend: FanHardwareControlling,
        state: FanHelperState,
        detail: String?
    ) -> FanHelperSnapshot {
        FanHelperSnapshot(
            model: backend.model,
            state: state,
            qualification: backend.qualification,
            aggregateTemperatureCelsius: nil,
            temperatureRecordedAt: nil,
            fans: [],
            verifiedDemand: nil,
            systemControlVerified: state == .systemControl,
            leaseExpiresAt: nil,
            detail: detail
        )
    }
}
