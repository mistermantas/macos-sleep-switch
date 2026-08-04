import Foundation

enum FanHardwareControllerTests {
    static func run() {
        testExternalControllerMatching()
        testQualifiedApplyAndRestore()
        testModeKeyFallback()
        testSystemTargetReboundRestores()
        testDelayedSystemReclaimRestores()
        testOwnedFansRestoreEvenIfMarkerDisappears()
        testUnexpectedTargetChangeLosesOwnership()
        testMissingTemperatureNeverWrites()
        testUnknownModelReportsUnsupportedTelemetry()
        testMonitoringOnlyNeverWrites()
    }

    private static func testExternalControllerMatching() {
        expect(
            ExternalFanControllerDetector.containsMacsFanControl(
                in: """
                /usr/bin/login
                /Applications/Macs Fan Control.app/Contents/MacOS/Macs Fan Control
                """
            ),
            "detects the installed Macs Fan Control executable"
        )
        expect(
            !ExternalFanControllerDetector.containsMacsFanControl(
                in: """
                /Applications/Macs Fan Control.app/Contents/Library/LaunchServices/com.crystalidea.macsfancontrol.smcwrite
                /usr/bin/grep Macs Fan Control
                """
            ),
            "does not treat the idle vendor helper or command text as the GUI controller"
        )
    }

    private static func testQualifiedApplyAndRestore() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sleep-switch-fan-controller-\(UUID().uuidString)",
            isDirectory: true
        )
        let marker = root.appendingPathComponent("lease")
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let smc = FakeSMCController()
        let fixture = qualifiedFixture()
        let controller = FanHardwareController(
            smc: smc,
            fixture: fixture,
            recoveryMarkerURL: marker,
            externalControllerDetector: { false },
            sleep: { _ in }
        )

        do {
            try controller.setRecoveryMarker(active: true)
            try controller.applyCoolingDemand(1)
            expect(
                smc.writtenKeys.contains("F0md")
                    && smc.writtenKeys.contains("F1md")
                    && smc.writtenKeys.contains("F0Tg")
                    && smc.writtenKeys.contains("F1Tg"),
                "writes only the qualified mode and target keys"
            )
            expect(
                smc.value("F0Ac") == 6_000
                    && smc.value("F1Ac") == 5_800,
                "verifies actual fan feedback at maximum"
            )

            try controller.restoreSystemControl()
            expect(
                smc.value("F0md") == 0
                    && smc.value("F1md") == 0
                    && smc.value("F0Tg") == 0
                    && smc.value("F1Tg") == 0
                    && smc.value("Ftst") == 0,
                "restores both fans and clears the unlock state"
            )
        } catch {
            fatalError("Test failed: qualified fake hardware returned \(error)")
        }
    }

    private static func testModeKeyFallback() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sleep-switch-fan-mode-key-\(UUID().uuidString)",
            isDirectory: true
        )
        let marker = root.appendingPathComponent("lease")
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let smc = FakeSMCController()
        smc.useUppercaseModeKeys()
        let controller = FanHardwareController(
            smc: smc,
            fixture: qualifiedFixture(),
            recoveryMarkerURL: marker,
            externalControllerDetector: { false },
            sleep: { _ in }
        )

        do {
            try controller.setRecoveryMarker(active: true)
            try controller.applyCoolingDemand(1)
            expect(
                smc.writtenKeys.contains("F0Md")
                    && smc.writtenKeys.contains("F1Md"),
                "falls back to the writable uppercase M4 mode keys"
            )
            try controller.restoreSystemControl()
            expect(
                smc.value("F0Md") == 0
                    && smc.value("F1Md") == 0,
                "restores the discovered uppercase mode keys"
            )
        } catch {
            fatalError("Test failed: mode-key fallback returned \(error)")
        }
    }

    private static func testSystemTargetReboundRestores() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sleep-switch-fan-target-rebound-\(UUID().uuidString)",
            isDirectory: true
        )
        let marker = root.appendingPathComponent("lease")
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let smc = FakeSMCController()
        let controller = FanHardwareController(
            smc: smc,
            fixture: qualifiedFixture(),
            recoveryMarkerURL: marker,
            externalControllerDetector: { false },
            sleep: { _ in }
        )

        do {
            try controller.setRecoveryMarker(active: true)
            try controller.applyCoolingDemand(1)
            smc.reboundsTargetAfterAutomaticRestore = true
            try controller.restoreSystemControl()
            expect(
                smc.value("F0Tg") == smc.value("F0Mn")
                    && smc.value("F1Tg") == smc.value("F1Mn"),
                "accepts macOS replacing zero with its automatic idle targets"
            )
        } catch {
            fatalError(
                "Test failed: automatic target rebound returned \(error)"
            )
        }
    }

    private static func testDelayedSystemReclaimRestores() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sleep-switch-fan-delayed-restore-\(UUID().uuidString)",
            isDirectory: true
        )
        let marker = root.appendingPathComponent("lease")
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        var time = Date(timeIntervalSince1970: 10_000)
        let smc = FakeSMCController()
        let controller = FanHardwareController(
            smc: smc,
            fixture: qualifiedFixture(),
            recoveryMarkerURL: marker,
            externalControllerDetector: { false },
            sleep: { interval in
                time.addTimeInterval(interval)
                smc.completePendingAutomaticModes()
            },
            now: { time }
        )

        do {
            try controller.setRecoveryMarker(active: true)
            try controller.applyCoolingDemand(1)
            smc.delaysAutomaticMode = true
            smc.delaysFtstClear = true
            smc.setFtst(1)
            try controller.restoreSystemControl()
            expect(
                smc.value("F0md") == 0
                    && smc.value("F1md") == 0,
                "waits for macOS to reclaim both fan modes"
            )
        } catch {
            fatalError(
                "Test failed: delayed system reclaim returned \(error)"
            )
        }
    }

    private static func testMonitoringOnlyNeverWrites() {
        let smc = FakeSMCController()
        let fixture = FanHardwareFixture.fixture(for: "Mac99,99")
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sleep-switch-monitoring-only-\(UUID().uuidString)"
        )
        let controller = FanHardwareController(
            smc: smc,
            fixture: fixture,
            recoveryMarkerURL: marker,
            externalControllerDetector: { false },
            sleep: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: marker) }

        do {
            try controller.setRecoveryMarker(active: true)
            try controller.applyCoolingDemand(1)
            fatalError("Test failed: monitoring-only hardware accepted a fan write")
        } catch let error as FanHardwareError {
            expect(
                error == .unqualifiedHardware,
                "rejects monitoring-only hardware before writing"
            )
        } catch {
            fatalError("Test failed: unexpected monitoring-only error \(error)")
        }
        expect(smc.writtenKeys.isEmpty, "performs no SMC write on monitoring-only hardware")
    }

    private static func testOwnedFansRestoreEvenIfMarkerDisappears() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sleep-switch-fan-marker-loss-\(UUID().uuidString)",
            isDirectory: true
        )
        let marker = root.appendingPathComponent("lease")
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let smc = FakeSMCController()
        let controller = FanHardwareController(
            smc: smc,
            fixture: qualifiedFixture(),
            recoveryMarkerURL: marker,
            externalControllerDetector: { false },
            sleep: { _ in }
        )

        do {
            try controller.setRecoveryMarker(active: true)
            try controller.applyCoolingDemand(1)
            try controller.setRecoveryMarker(active: false)
            try controller.restoreSystemControl()
            expect(
                smc.value("F0md") == 0
                    && smc.value("F1md") == 0
                    && smc.value("F0Tg") == 0
                    && smc.value("F1Tg") == 0,
                "restores an in-memory owned lease even if its marker disappears"
            )
        } catch {
            fatalError(
                "Test failed: marker-loss restoration returned \(error)"
            )
        }
    }

    private static func testMissingTemperatureNeverWrites() {
        let smc = FakeSMCController()
        smc.removeValue("Te05")
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sleep-switch-missing-temperature-\(UUID().uuidString)"
        )
        let controller = FanHardwareController(
            smc: smc,
            fixture: qualifiedFixture(),
            recoveryMarkerURL: marker,
            externalControllerDetector: { false },
            sleep: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: marker) }

        do {
            try controller.setRecoveryMarker(active: true)
            try controller.applyCoolingDemand(1)
            fatalError("Test failed: missing temperature accepted a fan write")
        } catch let error as FanHardwareError {
            expect(
                error == .invalidTelemetry,
                "rejects cooling when required temperature feedback is missing"
            )
        } catch {
            fatalError("Test failed: unexpected temperature error \(error)")
        }
        expect(
            smc.writtenKeys.isEmpty,
            "performs no SMC write without valid temperature feedback"
        )
    }

    private static func testUnknownModelReportsUnsupportedTelemetry() {
        let smc = FakeSMCController()
        let controller = FanHardwareController(
            smc: smc,
            fixture: .fixture(for: "Mac99,99"),
            externalControllerDetector: { false },
            sleep: { _ in }
        )

        do {
            let snapshot = try controller.snapshot(
                state: .monitoringOnly,
                verifiedDemand: nil,
                leaseExpiresAt: nil,
                detail: nil
            )
            expect(
                snapshot.state == .unsupported,
                "reports an unknown Mac as unsupported"
            )
            expect(
                snapshot.fans.count == 2,
                "keeps safe read-only fan telemetry on an unknown Mac"
            )
        } catch {
            fatalError("Test failed: unknown-model telemetry returned \(error)")
        }
        expect(
            smc.writtenKeys.isEmpty,
            "never writes while reporting unknown-model telemetry"
        )
    }

    private static func testUnexpectedTargetChangeLosesOwnership() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sleep-switch-fan-ownership-\(UUID().uuidString)",
            isDirectory: true
        )
        let marker = root.appendingPathComponent("lease")
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let smc = FakeSMCController()
        let controller = FanHardwareController(
            smc: smc,
            fixture: qualifiedFixture(),
            recoveryMarkerURL: marker,
            externalControllerDetector: { false },
            sleep: { _ in }
        )

        do {
            try controller.setRecoveryMarker(active: true)
            try controller.applyCoolingDemand(0.8)
            let writesBeforeInterference = smc.writtenKeys.count
            smc.setFloatValue("F0Tg", 2_500)

            do {
                try controller.applyCoolingDemand(0.9)
                fatalError("Test failed: an unexpected target change kept ownership")
            } catch let error as FanHardwareError {
                expect(
                    error == .ownershipLost,
                    "treats an unexpected target change as lost ownership"
                )
            }
            expect(
                smc.writtenKeys.count == writesBeforeInterference,
                "does not overwrite another controller after ownership is lost"
            )
        } catch {
            fatalError("Test failed: ownership fixture returned \(error)")
        }
    }

    private static func qualifiedFixture() -> FanHardwareFixture {
        FanHardwareFixture(
            model: "Mac16,7",
            cpuTemperatureKeys: ["Te05", "Tp01"],
            gpuTemperatureKeys: ["Tg1U"],
            auxiliaryTemperatureKeys: [],
            expectedFanCount: 2,
            modeKeyStyle: .lowercase,
            qualifiedRPMBounds: [
                .init(minimum: 1_500, maximum: 6_000),
                .init(minimum: 1_600, maximum: 5_800)
            ],
            requiresFtstUnlock: true,
            actualRPMTolerance: 10,
            spinUpTimeout: 1,
            minimumValidCPUReadings: 2,
            qualification: .maximumQualified
        )
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

private final class FakeSMCController: SMCControlling {
    private var values: [String: SMCReadValue] = [:]
    private(set) var writtenKeys: [String] = []
    var reboundsTargetAfterAutomaticRestore = false
    var delaysAutomaticMode = false
    var delaysFtstClear = false
    private var pendingAutomaticModeKeys: Set<String> = []
    private var pendingFtstClear = false

    init() {
        values = [
            "FNum": smcValue("FNum", "ui8 ", [2]),
            "F0Ac": floatSMCValue("F0Ac", 2_100),
            "F0Mn": floatSMCValue("F0Mn", 1_500),
            "F0Mx": floatSMCValue("F0Mx", 6_000),
            "F0Tg": floatSMCValue("F0Tg", 2_100),
            "F0md": smcValue("F0md", "ui8 ", [0]),
            "F1Ac": floatSMCValue("F1Ac", 2_200),
            "F1Mn": floatSMCValue("F1Mn", 1_600),
            "F1Mx": floatSMCValue("F1Mx", 5_800),
            "F1Tg": floatSMCValue("F1Tg", 2_200),
            "F1md": smcValue("F1md", "ui8 ", [0]),
            "Ftst": smcValue("Ftst", "ui8 ", [0]),
            "Te05": floatSMCValue("Te05", 50),
            "Tp01": floatSMCValue("Tp01", 55),
            "Tg1U": floatSMCValue("Tg1U", 48)
        ]
    }

    func readValue(forKey key: String) throws -> SMCReadValue? {
        values[key]
    }

    func writeValue(forKey key: String, bytes: [UInt8]) throws {
        guard let existing = values[key], existing.bytes.count == bytes.count else {
            throw FanHardwareError.writeFailed
        }
        writtenKeys.append(key)
        if delaysAutomaticMode,
           (key.hasSuffix("md") || key.hasSuffix("Md")),
           bytes.first == 0 {
            pendingAutomaticModeKeys.insert(key)
            return
        }
        if delaysFtstClear, key == "Ftst", bytes.first == 0 {
            pendingFtstClear = true
            return
        }
        values[key] = SMCReadValue(
            key: key,
            dataType: existing.dataType,
            bytes: bytes
        )

        if key.hasSuffix("Tg"), let target = values[key]?.doubleValue {
            let fanIndex = String(key.dropFirst().prefix(1))
            let actualKey = "F\(fanIndex)Ac"
            if reboundsTargetAfterAutomaticRestore,
               target == 0,
               let minimum = values["F\(fanIndex)Mn"]?.doubleValue {
                values[key] = floatSMCValue(key, Float(minimum))
                values[actualKey] = floatSMCValue(
                    actualKey,
                    Float(minimum)
                )
            } else {
                values[actualKey] = floatSMCValue(
                    actualKey,
                    Float(target)
                )
            }
        }
    }

    func value(_ key: String) -> Double? {
        values[key]?.doubleValue
    }

    func setFloatValue(_ key: String, _ number: Float) {
        values[key] = floatSMCValue(key, number)
        if key.hasSuffix("Tg") {
            let fanIndex = String(key.dropFirst().prefix(1))
            let actualKey = "F\(fanIndex)Ac"
            values[actualKey] = floatSMCValue(actualKey, number)
        }
    }

    func removeValue(_ key: String) {
        values.removeValue(forKey: key)
    }

    func useUppercaseModeKeys() {
        for index in 0..<2 {
            let lowercase = "F\(index)md"
            let uppercase = "F\(index)Md"
            values[uppercase] = values.removeValue(forKey: lowercase)
        }
    }

    func setFtst(_ value: UInt8) {
        values["Ftst"] = smcValue("Ftst", "ui8 ", [value])
    }

    func completePendingAutomaticModes() {
        for key in pendingAutomaticModeKeys {
            guard let existing = values[key], !existing.bytes.isEmpty else {
                continue
            }
            var bytes = existing.bytes
            bytes[0] = 0
            values[key] = SMCReadValue(
                key: key,
                dataType: existing.dataType,
                bytes: bytes
            )
        }
        pendingAutomaticModeKeys.removeAll()
        if pendingFtstClear {
            setFtst(0)
            pendingFtstClear = false
        }
    }

    private func smcValue(
        _ key: String,
        _ dataType: String,
        _ bytes: [UInt8]
    ) -> SMCReadValue {
        SMCReadValue(key: key, dataType: dataType, bytes: bytes)
    }

    private func floatSMCValue(
        _ key: String,
        _ number: Float
    ) -> SMCReadValue {
        var number = number
        return smcValue(
            key,
            "flt ",
            withUnsafeBytes(of: &number) { Array($0) }
        )
    }
}
