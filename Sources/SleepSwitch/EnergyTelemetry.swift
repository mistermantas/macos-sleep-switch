import Foundation
import IOKit.ps

protocol PowerTelemetryProviding {
    func read(at date: Date) -> EnergyReading
}

struct IOKitPowerTelemetryProvider: PowerTelemetryProviding {
    func read(at date: Date = Date()) -> EnergyReading {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return EnergyReading(
                recordedAt: date,
                watts: nil,
                source: .unavailable,
                confidence: .unavailable,
                batteryPercent: nil,
                isCharging: false
            )
        }

        let powerSourceType = IOPSGetProvidingPowerSourceType(blob)
            .map { $0.takeUnretainedValue() as String }
        let source: EnergySource = switch powerSourceType {
        case kIOPSBatteryPowerValue:
            .battery
        case kIOPSACPowerValue:
            .ac
        case "UPS":
            .ups
        default:
            .unavailable
        }

        var batteryPercent: Double?
        var watts: Double?
        var isCharging = false

        if let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
            as? [CFTypeRef],
           let sourceHandle = sources.first,
           let description = IOPSGetPowerSourceDescription(blob, sourceHandle)?
                .takeUnretainedValue() as? [String: Any] {
            let current = number(description[kIOPSCurrentKey])
            let voltage = number(description[kIOPSVoltageKey])
            // Some Macs expose the battery current/voltage description while
            // AC is providing the system. Keep the source label as AC, but
            // retain the reading as an estimate rather than pretending it is
            // a wall-meter measurement.
            if let current,
               let voltage,
               current.isFinite,
               voltage.isFinite {
                let estimatedWatts = abs(current * voltage) / 1_000_000
                if estimatedWatts > 0.01 {
                    watts = estimatedWatts
                }
            }

            let currentCapacity = number(description[kIOPSCurrentCapacityKey])
            let maxCapacity = number(description[kIOPSMaxCapacityKey])
            if let currentCapacity, let maxCapacity, maxCapacity > 0 {
                batteryPercent = max(0, min(100, currentCapacity / maxCapacity * 100))
            }
            isCharging = (description[kIOPSIsChargingKey] as? Bool) == true
        }

        return EnergyReading(
            recordedAt: date,
            watts: watts,
            source: source,
            confidence: watts == nil ? .unavailable : .estimated,
            batteryPercent: batteryPercent,
            isCharging: isCharging
        )
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }
}

struct FixturePowerTelemetryProvider: PowerTelemetryProviding {
    var reading: EnergyReading

    func read(at date: Date) -> EnergyReading {
        EnergyReading(
            recordedAt: date,
            watts: reading.watts,
            source: reading.source,
            confidence: reading.confidence,
            batteryPercent: reading.batteryPercent,
            isCharging: reading.isCharging
        )
    }
}
