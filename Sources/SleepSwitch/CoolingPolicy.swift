#if !APP_STORE
import Foundation

struct CoolingPolicyInput {
    let profile: CoolingProfile
    let ownsAwakeSession: Bool
    let temperature: TemperatureSample?
    let systemThermalLevel: SystemThermalLevel
    let previousDemand: Double?
    let previousDecisionAt: Date?
    let maximumCoolingVerified: Bool
    let aboveAbortCeilingSince: Date?
    let now: Date
    let aggressiveConfiguration: AggressiveCoolingConfiguration
    let leaseStartedAt: Date?

    init(
        profile: CoolingProfile,
        ownsAwakeSession: Bool,
        temperature: TemperatureSample?,
        systemThermalLevel: SystemThermalLevel,
        previousDemand: Double?,
        previousDecisionAt: Date?,
        maximumCoolingVerified: Bool,
        aboveAbortCeilingSince: Date?,
        now: Date,
        aggressiveConfiguration: AggressiveCoolingConfiguration = .defaults,
        leaseStartedAt: Date? = nil
    ) {
        self.profile = profile
        self.ownsAwakeSession = ownsAwakeSession
        self.temperature = temperature
        self.systemThermalLevel = systemThermalLevel
        self.previousDemand = previousDemand
        self.previousDecisionAt = previousDecisionAt
        self.maximumCoolingVerified = maximumCoolingVerified
        self.aboveAbortCeilingSince = aboveAbortCeilingSince
        self.now = now
        self.aggressiveConfiguration = aggressiveConfiguration
        self.leaseStartedAt = leaseStartedAt
    }
}

/// The comfort profile is intentionally reactive rather than a fixed fan
/// setting. A brief launch boost clears stored heat, then a cubic curve follows
/// the current sensor reading on every heartbeat. This keeps a lap-hot Mac
/// moving toward a comfortable temperature without pinning the fans after it
/// has cooled down.
struct AggressiveCoolingConfiguration: Equatable {
    static let comfortTargetDefaultsKey = "coolingAggressiveComfortTargetCelsius"
    static let launchBoostDefaultsKey = "coolingAggressiveLaunchBoostDemand"

    static let defaults = AggressiveCoolingConfiguration(
        comfortTargetCelsius: 55,
        launchBoostDemand: 0.92
    )

    let comfortTargetCelsius: Double
    let launchBoostDemand: Double

    init(comfortTargetCelsius: Double, launchBoostDemand: Double) {
        self.comfortTargetCelsius = min(max(comfortTargetCelsius, 45), 65)
        self.launchBoostDemand = min(max(launchBoostDemand, 0.70), 1)
    }

    init(defaults: UserDefaults = .standard) {
        let storedTarget = defaults.object(forKey: Self.comfortTargetDefaultsKey) as? Double
        let storedBoost = defaults.object(forKey: Self.launchBoostDefaultsKey) as? Double
        self.init(
            comfortTargetCelsius: storedTarget ?? Self.defaults.comfortTargetCelsius,
            launchBoostDemand: storedBoost ?? Self.defaults.launchBoostDemand
        )
    }
}

enum CoolingAbortReason: String, Equatable {
    case criticalSystemThermalState
    case invalidTemperature
    case missingTemperature
    case staleTemperature
    case sustainedHighTemperature
}

enum CoolingDecision: Equatable {
    case systemControl
    case demand(Double)
    case abort(CoolingAbortReason)
}

enum CoolingPolicy {
    static let minimumAggressiveDemand = 0.30
    static let aggressiveLaunchBoostDuration: TimeInterval = 24
    static let sampleLifetime: TimeInterval = 12
    static let abortCeilingCelsius = 80.0
    static let abortCeilingGrace: TimeInterval = 30
    static let maximumDemandDecreasePerTenSeconds = 0.25

    static func decide(_ input: CoolingPolicyInput) -> CoolingDecision {
        guard input.ownsAwakeSession else {
            return .systemControl
        }
        guard input.profile != .systemControl else {
            return .systemControl
        }
        guard input.systemThermalLevel != .critical else {
            return .abort(.criticalSystemThermalState)
        }
        guard let temperature = input.temperature else {
            return .abort(.missingTemperature)
        }
        guard temperature.isValid else {
            return .abort(.invalidTemperature)
        }
        guard input.now.timeIntervalSince(temperature.recordedAt) <= sampleLifetime,
              input.now >= temperature.recordedAt
        else {
            return .abort(.staleTemperature)
        }
        if input.maximumCoolingVerified,
           temperature.aggregateCelsius >= abortCeilingCelsius,
           let aboveAbortCeilingSince = input.aboveAbortCeilingSince,
           input.now.timeIntervalSince(aboveAbortCeilingSince)
                >= abortCeilingGrace {
            return .abort(.sustainedHighTemperature)
        }

        let requested: Double
        if input.profile == .maximum || input.systemThermalLevel == .serious {
            requested = 1
        } else {
            let curveDemand = aggressiveDemand(
                temperature: temperature.aggregateCelsius,
                configuration: input.aggressiveConfiguration
            )
            let isInLaunchBoost = input.leaseStartedAt.map {
                input.now.timeIntervalSince($0) < aggressiveLaunchBoostDuration
            } ?? false
            requested = isInLaunchBoost
                ? max(curveDemand, input.aggressiveConfiguration.launchBoostDemand)
                : curveDemand
        }

        return .demand(
            rateLimitedDemand(
                requested,
                previousDemand: input.previousDemand,
                previousDecisionAt: input.previousDecisionAt,
                now: input.now
            )
        )
    }

    static func aggressiveDemand(
        temperature: Double,
        configuration: AggressiveCoolingConfiguration
    ) -> Double {
        // A cubic ease-in is a Bezier-like curve: at the comfort target it is
        // deliberately quiet, but it steepens quickly before lap-uncomfortable
        // temperatures. `maximumAt` remains well below the 80°C safety abort.
        let floor = configuration.comfortTargetCelsius - 10
        let maximumAt = configuration.comfortTargetCelsius + 15
        let progress = clamped(
            (temperature - floor) / (maximumAt - floor),
            lower: 0,
            upper: 1
        )
        // Cubic smoothstep is the Bezier-equivalent curve from 0 to 1: calm
        // around the comfort target, increasingly decisive as heat rises.
        let cubicEase = progress * progress * (3 - 2 * progress)
        return minimumAggressiveDemand
            + cubicEase * (1 - minimumAggressiveDemand)
    }

    static func rpm(
        forDemand demand: Double,
        minimumRPM: Double,
        maximumRPM: Double
    ) -> Double? {
        guard demand.isFinite,
              minimumRPM.isFinite,
              maximumRPM.isFinite,
              minimumRPM >= 0,
              maximumRPM > minimumRPM
        else {
            return nil
        }

        let safeDemand = clamped(demand, lower: 0, upper: 1)
        return minimumRPM + safeDemand * (maximumRPM - minimumRPM)
    }

    private static func rateLimitedDemand(
        _ requested: Double,
        previousDemand: Double?,
        previousDecisionAt: Date?,
        now: Date
    ) -> Double {
        let requested = clamped(requested, lower: 0, upper: 1)
        guard let previousDemand,
              let previousDecisionAt,
              previousDemand.isFinite,
              (0...1).contains(previousDemand),
              previousDecisionAt <= now,
              previousDemand > requested
        else {
            return requested
        }

        let elapsed = max(0, now.timeIntervalSince(previousDecisionAt))
        let allowedDecrease = maximumDemandDecreasePerTenSeconds
            * (elapsed / 10)
        return max(requested, previousDemand - allowedDecrease)
    }

    private static func clamped(
        _ value: Double,
        lower: Double,
        upper: Double
    ) -> Double {
        min(max(value, lower), upper)
    }
}
#endif
