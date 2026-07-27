import Foundation

struct FanTelemetry: Equatable {
    let index: Int
    let actualRPM: Double
    let minimumRPM: Double?
    let maximumRPM: Double?
    let targetRPM: Double?
    let mode: Int?

    var hasValidBounds: Bool {
        guard let minimumRPM, let maximumRPM else { return false }
        return minimumRPM >= 0
            && maximumRPM > minimumRPM
            && maximumRPM <= 20_000
    }
}

struct CoolingTelemetrySnapshot: Equatable {
    let model: String
    let fixtureQualification: FanControlQualification
    let temperature: TemperatureSample?
    let temperatureReadings: [String: Double]
    let fans: [FanTelemetry]
    let recordedAt: Date

    var diagnosticSummary: String {
        let temperatureText: String
        if let temperature {
            temperatureText = String(
                format: "%.1f°C (%d sensors)",
                temperature.aggregateCelsius,
                temperature.sensorCount
            )
        } else {
            temperatureText = "unavailable"
        }

        let fanText = fans.map {
            let maximum = $0.maximumRPM.map { String(format: "%.0f", $0) } ?? "?"
            return "\($0.index):\(Int($0.actualRPM))/\(maximum)"
        }.joined(separator: ",")

        return "model=\(model) qualification=\(fixtureQualification) "
            + "temperature=\(temperatureText) fans=[\(fanText)]"
    }
}

final class TemperatureMonitor {
    private let reader: SMCValueReading
    let fixture: FanHardwareFixture

    init(reader: SMCValueReading, fixture: FanHardwareFixture) {
        self.reader = reader
        self.fixture = fixture
    }

    convenience init() throws {
        let model = SMCConnection.hardwareModel()
        try self.init(
            reader: SMCConnection(),
            fixture: .fixture(for: model)
        )
    }

    func snapshot(at date: Date = Date()) -> CoolingTelemetrySnapshot {
        let temperatureReadings = readTemperatureReadings()
        return CoolingTelemetrySnapshot(
            model: fixture.model,
            fixtureQualification: fixture.qualification,
            temperature: temperatureSample(
                from: temperatureReadings,
                at: date
            ),
            temperatureReadings: temperatureReadings,
            fans: readFans(),
            recordedAt: date
        )
    }

    private func temperatureSample(
        from readings: [String: Double],
        at date: Date
    ) -> TemperatureSample? {
        let cpu = values(
            for: fixture.cpuTemperatureKeys,
            in: readings
        )
        guard cpu.count >= fixture.minimumValidCPUReadings else {
            return nil
        }
        let gpu = values(
            for: fixture.gpuTemperatureKeys,
            in: readings
        )
        let auxiliary = values(
            for: fixture.auxiliaryTemperatureKeys,
            in: readings
        )
        let all = cpu + gpu + auxiliary

        return TemperatureSample(
            cpuAverageCelsius: cpu.reduce(0, +) / Double(cpu.count),
            gpuAverageCelsius: gpu.isEmpty
                ? nil
                : gpu.reduce(0, +) / Double(gpu.count),
            hottestCelsius: all.max() ?? cpu.max() ?? 0,
            sensorCount: all.count,
            recordedAt: date
        )
    }

    private func readTemperatureReadings() -> [String: Double] {
        let keys = fixture.cpuTemperatureKeys
            + fixture.gpuTemperatureKeys
            + fixture.auxiliaryTemperatureKeys
        var readings: [String: Double] = [:]
        for key in keys where readings[key] == nil {
            guard let value = try? reader.readValue(forKey: key)?.doubleValue,
                  value.isFinite,
                  (10...120).contains(value)
            else {
                continue
            }
            readings[key] = value
        }
        return readings
    }

    private func values(
        for keys: [String],
        in readings: [String: Double]
    ) -> [Double] {
        keys.compactMap { readings[$0] }
    }

    private func readFans() -> [FanTelemetry] {
        guard let countValue = try? reader.readValue(forKey: "FNum")?.doubleValue,
              countValue.isFinite,
              countValue.rounded() == countValue,
              (1...8).contains(countValue)
        else {
            return []
        }

        let count = Int(countValue)
        return (0..<count).compactMap { index in
            guard let actual = readRPM("F\(index)Ac") else {
                return nil
            }
            let lowerMode = readInteger("F\(index)md")
            let upperMode = readInteger("F\(index)Md")

            return FanTelemetry(
                index: index,
                actualRPM: actual,
                minimumRPM: readRPM("F\(index)Mn"),
                maximumRPM: readRPM("F\(index)Mx"),
                targetRPM: readRPM("F\(index)Tg"),
                mode: lowerMode ?? upperMode
            )
        }
    }

    private func readRPM(_ key: String) -> Double? {
        guard let value = try? reader.readValue(forKey: key)?.doubleValue,
              value.isFinite,
              (0...20_000).contains(value)
        else {
            return nil
        }
        return value
    }

    private func readInteger(_ key: String) -> Int? {
        guard let value = try? reader.readValue(forKey: key)?.doubleValue,
              value.isFinite,
              value.rounded() == value,
              (-1...255).contains(value)
        else {
            return nil
        }
        return Int(value)
    }
}
