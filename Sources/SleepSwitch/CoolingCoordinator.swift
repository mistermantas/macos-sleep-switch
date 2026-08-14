#if !APP_STORE
import Foundation

struct CoolingPresentationSnapshot {
    let selectedProfile: CoolingProfile
    let registrationState: FanHelperRegistrationState
    let helperSnapshot: FanHelperSnapshot?
    let message: String?
    let controlEnabled: Bool
    let hasActiveLease: Bool

    var effectiveTitle: String {
        guard let helperSnapshot else {
            return switch registrationState {
            case .requiresSignedBuild:
                "Signed Build Required"
            case .notRegistered:
                "Helper Not Installed"
            case .enabled:
                "Connecting…"
            case .requiresApproval:
                "Approval Needed"
            case .notFound:
                "Unavailable"
            }
        }

        return switch helperSnapshot.state {
        case .systemControl:
            "System Control"
        case .cooling:
            hasActiveLease ? selectedProfile.menuTitle : "Cooling Active"
        case .monitoringOnly:
            "Monitoring Only"
        case .unsupported:
            "Unsupported"
        case .externalControllerConflict:
            "Macs Fan Control"
        case .unavailable:
            "Unavailable"
        case .restoreFailed:
            "Check Fan Control"
        }
    }
}

final class CoolingCoordinator {
    static let profileDefaultsKey = "coolingProfile"

    private let client: FanHelperClienting
    private let defaults: UserDefaults
    private let thermalMonitor: ProcessInfoThermalMonitor
    private var heartbeatTimer: Timer?
    private var controlEnabled = false
    private var leaseToken: UUID?
    private var helperSnapshot: FanHelperSnapshot?
    private var message: String?
    private var previousDemand: Double?
    private var previousDecisionAt: Date?
    private var requestInFlight = false
    private var leaseStartBlocked = false
    private var aboveAbortCeilingSince: Date?

    var onChange: ((CoolingPresentationSnapshot) -> Void)?
    var onThermalAbort: ((CoolingAbortReason) -> Void)?

    init(
        client: FanHelperClienting,
        defaults: UserDefaults = .standard,
        thermalMonitor: ProcessInfoThermalMonitor =
            ProcessInfoThermalMonitor()
    ) {
        self.client = client
        self.defaults = defaults
        self.thermalMonitor = thermalMonitor
        defaults.register(defaults: [
            Self.profileDefaultsKey: CoolingProfile.systemControl.rawValue
        ])
    }

    var selectedProfile: CoolingProfile {
        let rawValue = defaults.string(forKey: Self.profileDefaultsKey)
        return CoolingProfile(rawValue: rawValue ?? "")
            ?? .systemControl
    }

    var presentation: CoolingPresentationSnapshot {
        CoolingPresentationSnapshot(
            selectedProfile: selectedProfile,
            registrationState: client.registrationState,
            helperSnapshot: helperSnapshot,
            message: message,
            controlEnabled: controlEnabled,
            hasActiveLease: leaseToken != nil
        )
    }

    func start() {
        guard heartbeatTimer == nil else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: FanHelperConstants.heartbeatInterval,
            repeats: true
        ) { [weak self] _ in
            self?.heartbeat()
        }
        timer.tolerance = 0.5
        heartbeatTimer = timer
        refreshStatus()
    }

    func stop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        endLease()
    }

    func selectProfile(_ profile: CoolingProfile) {
        guard profile != selectedProfile else { return }
        leaseStartBlocked = false
        defaults.set(profile.rawValue, forKey: Self.profileDefaultsKey)
        if profile == .systemControl || !controlEnabled {
            endLease()
        } else {
            endLease { [weak self] restored in
                guard let self else { return }
                if restored {
                    self.reconcile()
                } else {
                    self.leaseStartBlocked = true
                }
            }
        }
        publish()
    }

    func updateControlEnabled(_ controlEnabled: Bool) {
        guard self.controlEnabled != controlEnabled else {
            reconcile()
            return
        }
        self.controlEnabled = controlEnabled
        if controlEnabled {
            leaseStartBlocked = false
            reconcile()
        } else {
            endLease()
        }
        publish()
    }

    func refreshStatus() {
        leaseStartBlocked = false
        guard client.registrationState == .enabled else {
            helperSnapshot = nil
            message = registrationMessage
            publish()
            return
        }
        guard !requestInFlight else { return }
        requestInFlight = true
        client.status { [weak self] response in
            guard let self else { return }
            self.requestInFlight = false
            self.consume(response)
            if response.succeeded {
                self.reconcile()
            } else {
                self.leaseStartBlocked = true
            }
        }
    }

    func heartbeat(now: Date = Date()) {
        guard !requestInFlight else { return }
        guard controlEnabled,
              selectedProfile != .systemControl
        else {
            if leaseToken != nil {
                endLease()
            } else {
                refreshStatus()
            }
            return
        }
        guard let token = leaseToken,
              let helperSnapshot
        else {
            reconcile()
            return
        }

        let temperature = helperSnapshot
            .optionalAggregateTemperatureCelsius
            .map {
                TemperatureSample(
                    cpuAverageCelsius: $0,
                    gpuAverageCelsius: nil,
                    hottestCelsius: $0,
                    sensorCount: max(1, helperSnapshot.fans.count),
                    recordedAt:
                        helperSnapshot.temperatureRecordedAt ?? .distantPast
                )
            }
        let maximumCoolingVerified =
            helperSnapshot.state == .cooling
            && (helperSnapshot.optionalVerifiedDemand ?? 0) >= 0.99
        if let temperature,
           maximumCoolingVerified,
           temperature.aggregateCelsius
                >= CoolingPolicy.abortCeilingCelsius {
            if aboveAbortCeilingSince == nil {
                aboveAbortCeilingSince = now
            }
        } else {
            aboveAbortCeilingSince = nil
        }
        let decision = CoolingPolicy.decide(
            CoolingPolicyInput(
                profile: selectedProfile,
                ownsAwakeSession: controlEnabled,
                temperature: temperature,
                systemThermalLevel: thermalMonitor.currentLevel,
                previousDemand: previousDemand,
                previousDecisionAt: previousDecisionAt,
                maximumCoolingVerified: maximumCoolingVerified,
                aboveAbortCeilingSince: aboveAbortCeilingSince,
                now: now
            )
        )

        switch decision {
        case .systemControl:
            endLease()
        case .abort(let reason):
            endLease()
            onThermalAbort?(reason)
        case .demand(let demand):
            requestInFlight = true
            client.renewLease(
                token: token,
                demand: demand
            ) { [weak self] response in
                guard let self else { return }
                self.requestInFlight = false
                if response.succeeded {
                    self.previousDemand = demand
                    self.previousDecisionAt = now
                } else {
                    self.leaseStartBlocked = true
                }
                self.consume(response)
            }
        }
    }

    private func reconcile() {
        guard controlEnabled,
              selectedProfile != .systemControl,
              leaseToken == nil,
              !requestInFlight,
              !leaseStartBlocked
        else {
            return
        }
        guard client.registrationState == .enabled else {
            message = registrationMessage
            publish()
            return
        }

        let requestedProfile: FanHelperRequestedProfile =
            selectedProfile == .maximum ? .maximum : .aggressive
        if let helperSnapshot,
           !qualification(
               helperSnapshot.qualification,
               permits: requestedProfile
           ) {
            leaseStartBlocked = true
            message = "Cooling control is not qualified for this Mac."
            publish()
            return
        }
        requestInFlight = true
        client.beginLease(profile: requestedProfile) {
            [weak self] response in
            guard let self else { return }
            self.requestInFlight = false
            self.consume(response)
            if response.succeeded {
                self.previousDemand =
                    response.snapshot.optionalVerifiedDemand
                self.previousDecisionAt = Date()
            } else {
                self.leaseStartBlocked = true
            }
        }
    }

    private func endLease(
        completion: ((Bool) -> Void)? = nil
    ) {
        aboveAbortCeilingSince = nil
        guard let token = leaseToken else {
            previousDemand = nil
            previousDecisionAt = nil
            completion?(helperSnapshot?.state != .restoreFailed)
            publish()
            return
        }

        leaseToken = nil
        previousDemand = nil
        previousDecisionAt = nil
        client.endLease(token: token) { [weak self] response in
            self?.consume(response)
            completion?(response.succeeded)
        }
    }

    private func consume(_ response: FanHelperResponse) {
        helperSnapshot = response.snapshot
        leaseToken = response.succeeded
            ? (response.leaseToken ?? leaseToken)
            : nil
        message = response.message
        publish()
    }

    private var registrationMessage: String? {
        switch client.registrationState {
        case .requiresSignedBuild:
            return "Cooling requires a signed build"
        case .enabled:
            return nil
        case .notRegistered:
            return "Cooling helper not installed"
        case .requiresApproval:
            return "Cooling helper needs approval"
        case .notFound:
            return "Cooling helper unavailable"
        }
    }

    private func qualification(
        _ qualification: FanControlQualification,
        permits profile: FanHelperRequestedProfile
    ) -> Bool {
        switch profile {
        case .systemControl:
            return true
        case .aggressive:
            return qualification.permitsAggressiveControl
        case .maximum:
            return qualification.permitsMaximumControl
        }
    }

    private func publish() {
        onChange?(presentation)
    }
}
#endif
