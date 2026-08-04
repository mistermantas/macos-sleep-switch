import Foundation

// This allowlist is compiled into the direct-build helper, never the App Store
// application. Runtime probing alone never upgrades a model's qualification.

struct FanHardwareFixture: Equatable {
    struct RPMBounds: Equatable {
        let minimum: Double
        let maximum: Double
    }

    enum ModeKeyStyle: Equatable {
        case lowercase
        case uppercase
    }

    let model: String
    let cpuTemperatureKeys: [String]
    let gpuTemperatureKeys: [String]
    let auxiliaryTemperatureKeys: [String]
    let expectedFanCount: Int?
    let modeKeyStyle: ModeKeyStyle?
    let qualifiedRPMBounds: [RPMBounds]
    let requiresFtstUnlock: Bool
    let actualRPMTolerance: Double
    let spinUpTimeout: TimeInterval
    let minimumValidCPUReadings: Int
    let qualification: FanControlQualification

    var isKnownModel: Bool {
        Self.knownModels[model] != nil
    }

    func diagnosticMetadata(
        temperatureReadings: [String: Double]
    ) -> String {
        let modePattern = switch modeKeyStyle {
        case .lowercase:
            "F#md"
        case .uppercase:
            "F#Md"
        case nil:
            "unavailable"
        }
        let expectedFans = expectedFanCount.map(String.init)
            ?? "unknown"
        let bounds = qualifiedRPMBounds.isEmpty
            ? "unqualified"
            : qualifiedRPMBounds.map {
                "\(Int($0.minimum))-\(Int($0.maximum))"
            }.joined(separator: ",")
        let cpuReadings = diagnosticReadings(
            keys: cpuTemperatureKeys,
            readings: temperatureReadings
        )
        let gpuReadings = diagnosticReadings(
            keys: gpuTemperatureKeys,
            readings: temperatureReadings
        )
        let auxiliaryReadings = diagnosticReadings(
            keys: auxiliaryTemperatureKeys,
            readings: temperatureReadings
        )

        return [
            "fixture-known=\(isKnownModel)",
            "expected-fans=\(expectedFans)",
            "mode-key-pattern=\(modePattern)",
            "fan-rpm-key-patterns=F#Ac,F#Mn,F#Mx,F#Tg",
            "unlock-key=\(requiresFtstUnlock ? "Ftst" : "none")",
            "ftst-required=\(requiresFtstUnlock)",
            "qualified-rpm-bounds=\(bounds)",
            "minimum-cpu-readings=\(minimumValidCPUReadings)",
            "cpu-sensors=\(cpuReadings)",
            "gpu-sensors=\(gpuReadings)",
            "auxiliary-sensors=\(auxiliaryReadings)"
        ].joined(separator: "\n")
    }

    static func fixture(for model: String) -> FanHardwareFixture {
        knownModels[model] ?? FanHardwareFixture(
            model: model,
            cpuTemperatureKeys: [],
            gpuTemperatureKeys: [],
            auxiliaryTemperatureKeys: [],
            expectedFanCount: nil,
            modeKeyStyle: nil,
            qualifiedRPMBounds: [],
            requiresFtstUnlock: false,
            actualRPMTolerance: 0,
            spinUpTimeout: 0,
            minimumValidCPUReadings: 1,
            qualification: .monitoringOnly
        )
    }

    private static let knownModels: [String: FanHardwareFixture] = [
        "Mac16,7": FanHardwareFixture(
            model: "Mac16,7",
            cpuTemperatureKeys: [
                "Te05", "Te0S", "Te09", "Te0H",
                "Tp01", "Tp05", "Tp09", "Tp0D",
                "Tp0V", "Tp0Y", "Tp0b", "Tp0e"
            ],
            gpuTemperatureKeys: [
                "Tg1U", "Tg1k", "Tg0K", "Tg0L",
                "Tg0d", "Tg0e", "Tg0j", "Tg0k"
            ],
            auxiliaryTemperatureKeys: ["Tm0p", "Tm1p", "Tm2p"],
            expectedFanCount: 2,
            modeKeyStyle: .lowercase,
            // Qualified on physical Mac16,7 hardware running macOS 26.5.2.
            // The controller still requires these exact bounds at runtime
            // before it will write either fan.
            qualifiedRPMBounds: [
                .init(minimum: 1_350, maximum: 5_777),
                .init(minimum: 1_350, maximum: 5_777)
            ],
            requiresFtstUnlock: true,
            actualRPMTolerance: 250,
            spinUpTimeout: 30,
            minimumValidCPUReadings: 2,
            qualification: .adaptiveQualified
        )
    ]

    private func diagnosticReadings(
        keys: [String],
        readings: [String: Double]
    ) -> String {
        guard !keys.isEmpty else { return "none" }
        return keys.map { key in
            guard let value = readings[key] else {
                return "\(key)=unavailable"
            }
            return "\(key)=\(String(format: "%.1f", value))"
        }.joined(separator: ",")
    }
}
