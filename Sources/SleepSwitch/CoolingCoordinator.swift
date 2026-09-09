#if !APP_STORE
import Foundation

struct CoolingPresentationSnapshot {
    let selectedProfile: CoolingProfile
    let registrationState: FanHelperRegistrationState
    let helperSnapshot: FanHelperSnapshot?
    let message: String?
    let controlEnabled: Bool
    let hasActiveLease: Bool

    var failureReason: String? {
        switch registrationState {
        case .requiresSignedBuild:
            return "This copy of Sleep Switch is not signed for cooling."
        case .notRegistered, .notFound:
            return "The cooling helper is not installed for this copy of Sleep Switch."
        case .requiresApproval:
            return "macOS is waiting for you to approve the cooling helper."
        case .enabled:
            break
        }
        guard let snapshot = helperSnapshot else { return nil }
        switch snapshot.state {
        case .externalControllerConflict:
            return "Macs Fan Control is open, so Sleep Switch has paused its fan controls."
        case .unsupported:
            return "This Mac has no supported controllable fans."
        case .monitoringOnly:
            return message ?? snapshot.detail ?? "Fan control has not been verified for this Mac."
        case .unavailable:
            return message ?? snapshot.detail ?? "Sleep Switch could not read the cooling helper's status."
        case .restoreFailed:
            return message ?? snapshot.detail ?? "Sleep Switch could not verify that macOS regained fan control."
        case .systemControl:
            return message
        case .cooling:
            return nil
        }
    }

    var recoverySuggestion: String {
        switch registrationState {
        case .requiresSignedBuild:
            return "Install the signed Sleep Switch app, then try again."
        case .notRegistered, .notFound:
            return "Choose Install Cooling Helper in the Cooling menu."
        case .requiresApproval:
            return "Open System Settings → General → Login Items & Extensions and allow Sleep Switch to run in the background."
        case .enabled:
            break
        }
        switch helperSnapshot?.state {
        case .externalControllerConflict:
            return "Quit Macs Fan Control, then choose your cooling mode again."
        case .monitoringOnly, .unsupported:
            return "Use System Control. Cooling Details shows this Mac's hardware support."
        case .restoreFailed:
            return "Quit other fan-control apps and restart the Mac before trying again."
        default:
            return "Try your cooling mode again. If it still fails, quit Sleep Switch and reopen the signed copy in Applications."
        }
    }

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
            "Needs Attention"
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
    private var leaseStartedAt: Date?

    var onChange: ((CoolingPresentationSnapshot) -> Void)?
    var onProfileApplicationChange: (() -> Void)?
    var onThermalAbort: ((CoolingAbortReason) -> Void)?
    var onFailure: ((CoolingPresentationSnapshot) -> Void)?

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
            Self.profileDefaultsKey: CoolingProfile.systemControl.rawValue,
            AggressiveCoolingConfiguration.comfortTargetDefaultsKey: AggressiveCoolingConfiguration.defaults.comfortTargetCelsius,
            AggressiveCoolingConfiguration.launchBoostDefaultsKey: AggressiveCoolingConfiguration.defaults.launchBoostDemand
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
        onProfileApplicationChange?()
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
                now: now,
                aggressiveConfiguration: AggressiveCoolingConfiguration(defaults: defaults),
                leaseStartedAt: leaseStartedAt
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
           [.unavailable, .restoreFailed, .externalControllerConflict, .unsupported]
                .contains(helperSnapshot.state) {
            leaseStartBlocked = true
            publish()
            onFailure?(presentation)
            return
        }
        if let helperSnapshot,
           !qualification(
               helperSnapshot.qualification,
               permits: requestedProfile
           ) {
            leaseStartBlocked = true
            message = "Cooling control is not qualified for this Mac."
            publish()
            onFailure?(presentation)
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
                self.leaseStartedAt = self.previousDecisionAt
            } else {
                self.leaseStartBlocked = true
            }
            self.onProfileApplicationChange?()
        }
    }

    private func endLease(
        completion: ((Bool) -> Void)? = nil
    ) {
        aboveAbortCeilingSince = nil
        guard let token = leaseToken else {
            previousDemand = nil
            previousDecisionAt = nil
            leaseStartedAt = nil
            completion?(helperSnapshot?.state != .restoreFailed)
            publish()
            return
        }

        leaseToken = nil
        previousDemand = nil
        previousDecisionAt = nil
        leaseStartedAt = nil
        client.endLease(token: token) { [weak self] response in
            self?.consume(response)
            self?.onProfileApplicationChange?()
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
        if !response.succeeded || presentation.failureReason != nil {
            onFailure?(presentation)
        }
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
