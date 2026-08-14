#if !APP_STORE
import Foundation

enum CoolingDiagnosticsTests {
    static func run() {
        let generatedAt = Date(timeIntervalSince1970: 1_000)
        let snapshot = FanHelperSnapshot(
            model: "Mac16,7",
            state: .monitoringOnly,
            qualification: .monitoringOnly,
            aggregateTemperatureCelsius: 58.25,
            temperatureRecordedAt: Date(timeIntervalSince1970: 990),
            fans: [
                FanTelemetryMessage(
                    index: 0,
                    actualRPM: 2_100,
                    minimumRPM: 1_500,
                    maximumRPM: 6_000,
                    targetRPM: 2_400,
                    mode: 0
                )
            ],
            verifiedDemand: nil,
            systemControlVerified: true,
            leaseExpiresAt: nil,
            detail: nil,
            diagnosticMetadata:
                "fixture-known=true\ncpu-sensors=Te05=51.0"
        )
        let presentation = CoolingPresentationSnapshot(
            selectedProfile: .systemControl,
            registrationState: .enabled,
            helperSnapshot: snapshot,
            message: nil,
            controlEnabled: false,
            hasActiveLease: false
        )

        let report = CoolingDiagnosticReport.text(
            presentation: presentation,
            thermalLevel: .nominal,
            generatedAt: generatedAt,
            operatingSystem: "macOS Test",
            appVersion: "1.6.0"
        )

        for expected in [
            "generated-at=1970-01-01T00:16:40Z",
            "operating-system=macOS Test",
            "model=Mac16,7",
            "helper-state=monitoring-only",
            "temperature-celsius=58.2",
            "fan-1=actual:2100.0,min:1500.0,max:6000.0",
            "[fixture]",
            "cpu-sensors=Te05=51.0"
        ] {
            expect(
                report.contains(expected),
                "includes safe diagnostic field \(expected)"
            )
        }

        for forbidden in [
            "/Users/",
            "serial-number",
            "lease-token",
            "agent-content",
            "task-prompt"
        ] {
            expect(
                !report.localizedCaseInsensitiveContains(forbidden),
                "does not include personal or agent data: \(forbidden)"
            )
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
#endif
