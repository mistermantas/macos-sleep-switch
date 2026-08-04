import Foundation
import IOKit
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

        if let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue(),
           CFArrayGetCount(sources) > 0 {
            let sourcePointer = CFArrayGetValueAtIndex(sources, 0)
            let sourceHandle = unsafeBitCast(sourcePointer, to: CFTypeRef.self)
            guard let description = IOPSGetPowerSourceDescription(blob, sourceHandle)?
                .takeUnretainedValue() as? [String: Any] else {
                return EnergyReading(
                    recordedAt: date,
                    watts: nil,
                    source: source,
                    confidence: .unavailable,
                    batteryPercent: nil,
                    isCharging: false
                )
            }
            let current = number(description[kIOPSCurrentKey])
            let voltage = number(description[kIOPSVoltageKey]) ?? batteryVoltageMillivolts()
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
        } else if source == .battery {
            return EnergyReading(
                recordedAt: date,
                watts: nil,
                source: source,
                confidence: .unavailable,
                batteryPercent: nil,
                isCharging: false
            )
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

    private func batteryVoltageMillivolts() -> Double? {
        let matching = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        let key = ("Voltage" as NSString) as CFString
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            key,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return nil
        }
        return number(value)
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
