#if !APP_STORE
import Foundation

enum CoolingDiagnosticReport {
    static func text(
        presentation: CoolingPresentationSnapshot,
        thermalLevel: SystemThermalLevel,
        generatedAt: Date = Date(),
        operatingSystem: String =
            ProcessInfo.processInfo.operatingSystemVersionString,
        appVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
    ) -> String {
        let registration = registrationName(
            presentation.registrationState
        )
        var lines = [
            "Sleep Switch Cooling Diagnostics",
            "generated-at=\(iso8601(generatedAt))",
            "app-version=\(appVersion)",
            "operating-system=\(operatingSystem)",
            "thermal-state=\(thermalLevelName(thermalLevel))",
            "selected-profile=\(presentation.selectedProfile.rawValue)",
            "helper-registration=\(registration)",
            "control-enabled=\(presentation.controlEnabled)",
            "active-lease=\(presentation.hasActiveLease)"
        ]

        guard let snapshot = presentation.helperSnapshot else {
            lines.append("helper-snapshot=unavailable")
            return lines.joined(separator: "\n") + "\n"
        }

        let qualification = qualificationName(snapshot.qualification)
        let temperature = number(
            snapshot.optionalAggregateTemperatureCelsius
        )
        let temperatureDate = date(snapshot.temperatureRecordedAt)
        let verifiedDemand = number(snapshot.optionalVerifiedDemand)
        lines += [
            "model=\(singleLine(snapshot.model))",
            "helper-state=\(stateName(snapshot.state))",
            "qualification=\(qualification)",
            "temperature-celsius=\(temperature)",
            "temperature-recorded-at=\(temperatureDate)",
            "verified-demand=\(verifiedDemand)",
            "system-control-verified=\(snapshot.systemControlVerified)",
            "lease-expires-at=\(date(snapshot.leaseExpiresAt))",
            "fan-count=\(snapshot.fans.count)"
        ]

        for fan in snapshot.fans.sorted(by: { $0.index < $1.index }) {
            lines.append(
                "fan-\(fan.index + 1)="
                    + "actual:\(number(fan.actualRPM)),"
                    + "min:\(number(fan.optionalMinimumRPM)),"
                    + "max:\(number(fan.optionalMaximumRPM)),"
                    + "target:\(number(fan.optionalTargetRPM)),"
                    + "mode:\(fan.optionalMode.map(String.init) ?? "unavailable")"
            )
        }

        if let metadata = snapshot.diagnosticMetadata,
           !metadata.isEmpty {
            lines.append("[fixture]")
            lines.append(metadata)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func registrationName(
        _ state: FanHelperRegistrationState
    ) -> String {
        switch state {
        case .requiresSignedBuild:
            return "requires-signed-build"
        case .notRegistered:
            return "not-registered"
        case .enabled:
            return "enabled"
        case .requiresApproval:
            return "requires-approval"
        case .notFound:
            return "not-found"
        }
    }

    private static func stateName(_ state: FanHelperState) -> String {
        switch state {
        case .systemControl:
            return "system-control"
        case .cooling:
            return "cooling"
        case .monitoringOnly:
            return "monitoring-only"
        case .unsupported:
            return "unsupported"
        case .externalControllerConflict:
            return "external-controller-conflict"
        case .unavailable:
            return "unavailable"
        case .restoreFailed:
            return "restore-failed"
        }
    }

    private static func qualificationName(
        _ qualification: FanControlQualification
    ) -> String {
        switch qualification {
        case .monitoringOnly:
            return "monitoring-only"
        case .maximumQualified:
            return "maximum-qualified"
        case .adaptiveQualified:
            return "adaptive-qualified"
        }
    }

    private static func thermalLevelName(
        _ level: SystemThermalLevel
    ) -> String {
        switch level {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        }
    }

    private static func date(_ date: Date?) -> String {
        date.map(iso8601) ?? "unavailable"
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else {
            return "unavailable"
        }
        return String(format: "%.1f", value)
    }

    private static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
#endif
