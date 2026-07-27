import Foundation

enum CoolingPolicyTests {
    static func run() {
        let now = Date(timeIntervalSince1970: 10_000)

        expect(
            CoolingPolicy.decide(
                input(
                    profile: .maximum,
                    ownsAwakeSession: false,
                    temperature: sample(70, at: now),
                    now: now
                )
            ) == .systemControl,
            "restores system control without an owned awake session"
        )
        expect(
            CoolingPolicy.decide(
                input(
                    profile: .systemControl,
                    temperature: sample(70, at: now),
                    now: now
                )
            ) == .systemControl,
            "honors the system-control profile"
        )
        expect(
            CoolingPolicy.decide(
                input(
                    profile: .aggressive,
                    temperature: nil,
                    now: now
                )
            ) == .abort(.missingTemperature),
            "fails safe when temperature telemetry is missing"
        )
        expect(
            CoolingPolicy.decide(
                input(
                    profile: .maximum,
                    temperature: sample(
                        60,
                        at: now.addingTimeInterval(
                            -(CoolingPolicy.sampleLifetime + 1)
                        )
                    ),
                    now: now
                )
            ) == .abort(.staleTemperature),
            "fails safe when temperature telemetry is stale"
        )
        expect(
            CoolingPolicy.decide(
                input(
                    profile: .maximum,
                    temperature: sample(60, at: now),
                    thermalLevel: .critical,
                    now: now
                )
            ) == .abort(.criticalSystemThermalState),
            "aborts rather than fighting a critical macOS thermal state"
        )
        expectDemand(
            CoolingPolicy.decide(
                input(
                    profile: .aggressive,
                    temperature: sample(45, at: now),
                    now: now
                )
            ),
            equals: 0.5,
            "starts aggressive cooling at half demand below 50°C"
        )
        expectDemand(
            CoolingPolicy.decide(
                input(
                    profile: .aggressive,
                    temperature: sample(55, at: now),
                    now: now
                )
            ),
            equals: 0.75,
            "ramps aggressive cooling linearly between 50°C and 60°C"
        )
        expectDemand(
            CoolingPolicy.decide(
                input(
                    profile: .aggressive,
                    temperature: sample(60, at: now),
                    now: now
                )
            ),
            equals: 1,
            "reaches full demand by 60°C"
        )
        expectDemand(
            CoolingPolicy.decide(
                input(
                    profile: .aggressive,
                    temperature: sample(45, at: now),
                    thermalLevel: .serious,
                    now: now
                )
            ),
            equals: 1,
            "uses full demand when macOS reports serious thermal pressure"
        )
        expectDemand(
            CoolingPolicy.decide(
                input(
                    profile: .maximum,
                    temperature: sample(45, at: now),
                    now: now
                )
            ),
            equals: 1,
            "keeps maximum cooling independent of the normal curve"
        )
        expectDemand(
            CoolingPolicy.decide(
                input(
                    profile: .maximum,
                    temperature: sample(80, at: now),
                    maximumCoolingVerified: true,
                    aboveAbortCeilingSince:
                        now.addingTimeInterval(
                            -(CoolingPolicy.abortCeilingGrace - 1)
                        ),
                    now: now
                )
            ),
            equals: 1,
            "keeps maximum cooling through the high-temperature grace period"
        )
        expect(
            CoolingPolicy.decide(
                input(
                    profile: .maximum,
                    temperature: sample(80, at: now),
                    maximumCoolingVerified: true,
                    aboveAbortCeilingSince:
                        now.addingTimeInterval(
                            -CoolingPolicy.abortCeilingGrace
                        ),
                    now: now
                )
            ) == .abort(.sustainedHighTemperature),
            "aborts an awake session after sustained heat at verified maximum cooling"
        )
        expectDemand(
            CoolingPolicy.decide(
                input(
                    profile: .aggressive,
                    temperature: sample(45, at: now),
                    previousDemand: 1,
                    previousDecisionAt: now.addingTimeInterval(-30),
                    now: now
                )
            ),
            equals: 0.95,
            "limits downward fan demand changes"
        )
        expectDemand(
            CoolingPolicy.decide(
                input(
                    profile: .aggressive,
                    temperature: sample(45, at: now),
                    previousDemand: .infinity,
                    previousDecisionAt: now.addingTimeInterval(-30),
                    now: now
                )
            ),
            equals: 0.5,
            "ignores invalid prior demand instead of emitting an invalid request"
        )
        expect(
            CoolingPolicy.rpm(
                forDemand: 0.5,
                minimumRPM: 2_000,
                maximumRPM: 6_000
            ) == 4_000,
            "maps normalized demand into per-fan RPM bounds"
        )
        expect(
            CoolingPolicy.rpm(
                forDemand: 1,
                minimumRPM: 6_000,
                maximumRPM: 2_000
            ) == nil,
            "rejects inverted fan bounds"
        )
    }

    private static func input(
        profile: CoolingProfile,
        ownsAwakeSession: Bool = true,
        temperature: TemperatureSample?,
        thermalLevel: SystemThermalLevel = .nominal,
        previousDemand: Double? = nil,
        previousDecisionAt: Date? = nil,
        maximumCoolingVerified: Bool = false,
        aboveAbortCeilingSince: Date? = nil,
        now: Date
    ) -> CoolingPolicyInput {
        CoolingPolicyInput(
            profile: profile,
            ownsAwakeSession: ownsAwakeSession,
            temperature: temperature,
            systemThermalLevel: thermalLevel,
            previousDemand: previousDemand,
            previousDecisionAt: previousDecisionAt,
            maximumCoolingVerified: maximumCoolingVerified,
            aboveAbortCeilingSince: aboveAbortCeilingSince,
            now: now
        )
    }

    private static func sample(
        _ temperature: Double,
        at date: Date
    ) -> TemperatureSample {
        TemperatureSample(
            cpuAverageCelsius: temperature,
            gpuAverageCelsius: temperature,
            hottestCelsius: temperature,
            sensorCount: 4,
            recordedAt: date
        )
    }

    private static func expectDemand(
        _ decision: CoolingDecision,
        equals expected: Double,
        _ message: String
    ) {
        guard case .demand(let actual) = decision,
              abs(actual - expected) < 0.000_1
        else {
            fatalError("Test failed: \(message); got \(decision)")
        }
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
