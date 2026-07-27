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
    static let coolFloorCelsius = 50.0
    static let maximumAtCelsius = 60.0
    static let minimumAggressiveDemand = 0.5
    static let sampleLifetime: TimeInterval = 12
    static let abortCeilingCelsius = 80.0
    static let abortCeilingGrace: TimeInterval = 30
    static let maximumDemandDecreasePerThirtySeconds = 0.05

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
            let progress = (
                temperature.aggregateCelsius - coolFloorCelsius
            ) / (maximumAtCelsius - coolFloorCelsius)
            requested = minimumAggressiveDemand
                + clamped(progress, lower: 0, upper: 1)
                * (1 - minimumAggressiveDemand)
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
        let allowedDecrease = maximumDemandDecreasePerThirtySeconds
            * (elapsed / 30)
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
