#if !APP_STORE
import Foundation

struct TemperatureSample: Equatable {
    let cpuAverageCelsius: Double
    let gpuAverageCelsius: Double?
    let hottestCelsius: Double
    let sensorCount: Int
    let recordedAt: Date

    var aggregateCelsius: Double {
        max(cpuAverageCelsius, gpuAverageCelsius ?? cpuAverageCelsius, hottestCelsius)
    }

    var isValid: Bool {
        let values = [
            cpuAverageCelsius,
            gpuAverageCelsius ?? cpuAverageCelsius,
            hottestCelsius
        ]
        return sensorCount > 0
            && values.allSatisfy { $0.isFinite && (10...120).contains($0) }
    }
}
#endif
