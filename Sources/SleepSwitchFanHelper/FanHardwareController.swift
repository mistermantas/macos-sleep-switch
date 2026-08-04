import Foundation

final class FanHardwareController: FanHardwareControlling {
    let model: String
    let qualification: FanControlQualification

    private let smc: SMCControlling
    private let fixture: FanHardwareFixture
    private let monitor: TemperatureMonitor
    private let recoveryMarkerURL: URL
    private let externalControllerDetector: () -> Bool
    private let sleep: (TimeInterval) -> Void
    private let now: () -> Date
    private var lastAppliedDemand: Double?
    private var activeModeKeys: [Int: String] = [:]

    init(
        smc: SMCControlling,
        fixture: FanHardwareFixture,
        recoveryMarkerURL: URL = URL(
            fileURLWithPath: "/var/run/lt.mantas.sleepswitch.fanlease"
        ),
        externalControllerDetector: @escaping () -> Bool = {
            ExternalFanControllerDetector().isMacsFanControlRunning()
        },
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep,
        now: @escaping () -> Date = Date.init
    ) {
        self.smc = smc
        self.fixture = fixture
        model = fixture.model
        qualification = fixture.qualification
        monitor = TemperatureMonitor(reader: smc, fixture: fixture)
        self.recoveryMarkerURL = recoveryMarkerURL
        self.externalControllerDetector = externalControllerDetector
        self.sleep = sleep
        self.now = now
    }

    convenience init() throws {
        let smc = try SMCConnection()
        let model = SMCConnection.hardwareModel()
        self.init(smc: smc, fixture: .fixture(for: model))
    }

    func externalControllerIsRunning() -> Bool {
        externalControllerDetector()
    }

    func hasRecoveryMarker() -> Bool {
        FileManager.default.fileExists(atPath: recoveryMarkerURL.path)
    }

    func setRecoveryMarker(active: Bool) throws {
        if active {
            try Data("active\n".utf8).write(
                to: recoveryMarkerURL,
                options: .atomic
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: recoveryMarkerURL.path
            )
        } else if hasRecoveryMarker() {
            try FileManager.default.removeItem(at: recoveryMarkerURL)
        }
    }

    func snapshot(
        state: FanHelperState,
        verifiedDemand: Double?,
        leaseExpiresAt: Date?,
        detail: String?
    ) throws -> FanHelperSnapshot {
        let telemetry = monitor.snapshot(at: now())
        if fixture.isKnownModel {
            guard fanLayoutMatches(
                telemetry.fans,
                requireQualifiedBounds: false
            ) else {
                throw FanHardwareError.invalidTelemetry
            }
        } else {
            guard genericFanTelemetryIsValid(telemetry.fans) else {
                throw FanHardwareError.invalidTelemetry
            }
        }

        let systemControlVerified = systemControlIsVerified(
            fanCount: telemetry.fans.count
        )

        return FanHelperSnapshot(
            model: model,
            state: fixture.isKnownModel ? state : .unsupported,
            qualification: qualification,
            aggregateTemperatureCelsius:
                telemetry.temperature?.aggregateCelsius,
            temperatureRecordedAt:
                telemetry.temperature?.recordedAt,
            fans: telemetry.fans.map {
                FanTelemetryMessage(
                    index: $0.index,
                    actualRPM: $0.actualRPM,
                    minimumRPM: $0.minimumRPM,
                    maximumRPM: $0.maximumRPM,
                    targetRPM: $0.targetRPM,
                    mode: try? readMode(forFan: $0.index)
                )
            },
            verifiedDemand: verifiedDemand,
            systemControlVerified: systemControlVerified,
            leaseExpiresAt: leaseExpiresAt,
            detail: detail,
            diagnosticMetadata: fixture.diagnosticMetadata(
                temperatureReadings: telemetry.temperatureReadings
            )
        )
    }

    func applyCoolingDemand(_ demand: Double) throws {
        guard qualification.permitsMaximumControl else {
            throw FanHardwareError.unqualifiedHardware
        }
        guard demand.isFinite, (0...1).contains(demand) else {
            throw FanHardwareError.invalidTelemetry
        }
        guard hasRecoveryMarker() else {
            throw FanHardwareError.writeFailed
        }
        guard !externalControllerIsRunning() else {
            throw FanHardwareError.externalControllerConflict
        }

        let before = monitor.snapshot(at: now())
        guard fanLayoutMatches(before.fans, requireQualifiedBounds: true) else {
            throw FanHardwareError.invalidTelemetry
        }
        guard let temperature = before.temperature,
              temperature.isValid
        else {
            throw FanHardwareError.invalidTelemetry
        }
        guard ownershipIsIntact(before.fans) else {
            throw FanHardwareError.ownershipLost
        }

        for fan in before.fans {
            guard let minimum = fan.minimumRPM,
                  let maximum = fan.maximumRPM
            else {
                throw FanHardwareError.invalidTelemetry
            }
            let target = minimum + demand * (maximum - minimum)
            try setManualMode(forFan: fan.index)
            try writeRPM(target, key: "F\(fan.index)Tg")
        }

        guard waitForAppliedDemand(
            demand,
            timeout: fixture.spinUpTimeout
        ) else {
            throw FanHardwareError.verificationFailed
        }
        lastAppliedDemand = demand
    }

    func restoreSystemControl() throws {
        guard hasRecoveryMarker() || lastAppliedDemand != nil else {
            return
        }

        let count = try readFanCount()
        guard let expected = fixture.expectedFanCount,
              count == expected,
              fixture.modeKeyStyle != nil
        else {
            throw FanHardwareError.restoreFailed
        }

        var encounteredFailure = false
        for index in 0..<count {
            do {
                try requestAutomaticMode(forFan: index)
            } catch {
                encounteredFailure = true
            }
            // Once the mode is automatic/system, macOS owns the target. Some
            // Apple Silicon Macs immediately replace a zero target with their
            // current idle target, so target equality is not a restoration
            // invariant.
            try? writeRPM(0, key: "F\(index)Tg")
        }

        if fixture.requiresFtstUnlock {
            try? writeFirstByte(0, key: "Ftst")
        }

        // M3/M4 firmware can ignore the first automatic-mode request while
        // Ftst is still active. Retry once after clearing Ftst, then keep
        // retrying during the bounded verification window.
        for index in 0..<count {
            try? requestAutomaticMode(forFan: index)
        }

        guard !encounteredFailure,
              waitForSystemControl(
                  fanCount: count,
                  timeout: min(12, fixture.spinUpTimeout)
              )
        else {
            throw FanHardwareError.restoreFailed
        }
        lastAppliedDemand = nil
    }

    private func fanLayoutMatches(
        _ fans: [FanTelemetry],
        requireQualifiedBounds: Bool
    ) -> Bool {
        guard let expectedFanCount = fixture.expectedFanCount,
              fans.count == expectedFanCount,
              fans.indices.allSatisfy({ fans[$0].index == $0 }),
              fans.allSatisfy(\.hasValidBounds)
        else {
            return false
        }

        guard requireQualifiedBounds else {
            return true
        }
        guard fixture.qualifiedRPMBounds.count == fans.count else {
            return false
        }

        return zip(fans, fixture.qualifiedRPMBounds).allSatisfy {
            fan, qualified in
            guard let minimum = fan.minimumRPM,
                  let maximum = fan.maximumRPM
            else {
                return false
            }
            return abs(minimum - qualified.minimum) <= 5
                && abs(maximum - qualified.maximum) <= 5
        }
    }

    private func genericFanTelemetryIsValid(
        _ fans: [FanTelemetry]
    ) -> Bool {
        guard fans.count <= 8,
              fans.indices.allSatisfy({ fans[$0].index == $0 })
        else {
            return false
        }
        return fans.allSatisfy {
            $0.actualRPM.isFinite
                && (0...20_000).contains($0.actualRPM)
                && $0.hasValidBounds
        }
    }

    private func setManualMode(forFan index: Int) throws {
        let candidates = modeKeyCandidates(forFan: index)
        guard !candidates.isEmpty else {
            throw FanHardwareError.writeFailed
        }

        for key in candidates {
            do {
                try writeMode(1, key: key)
                if try readMode(forKey: key) == 1 {
                    activeModeKeys[index] = key
                    return
                }
            } catch {
                continue
            }
        }

        guard fixture.requiresFtstUnlock else {
            throw FanHardwareError.writeFailed
        }
        try writeFirstByte(1, key: "Ftst")
        sleep(3)

        let deadline = now().addingTimeInterval(
            min(30, fixture.spinUpTimeout)
        )
        repeat {
            for key in candidates {
                try? writeMode(1, key: key)
                if (try? readMode(forKey: key)) == 1 {
                    activeModeKeys[index] = key
                    return
                }
            }
            sleep(0.1)
        } while now() < deadline

        throw FanHardwareError.writeFailed
    }

    private func requestAutomaticMode(forFan index: Int) throws {
        let candidates = modeKeyCandidates(forFan: index)
        var foundModeKey = false

        for key in candidates {
            guard (try? readMode(forKey: key)) != nil else {
                continue
            }
            foundModeKey = true
            try? writeMode(0, key: key)
        }

        activeModeKeys.removeValue(forKey: index)
        guard foundModeKey else {
            throw FanHardwareError.restoreFailed
        }
    }

    private func waitForAppliedDemand(
        _ demand: Double,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = now().addingTimeInterval(min(30, timeout))
        repeat {
            let telemetry = monitor.snapshot(at: now())
            if fanLayoutMatches(
                telemetry.fans,
                requireQualifiedBounds: true
            ), zip(telemetry.fans, fixture.qualifiedRPMBounds).allSatisfy({
                fan, bounds in
                let expected = bounds.minimum
                    + demand * (bounds.maximum - bounds.minimum)
                guard (try? readMode(forFan: fan.index)) == 1,
                      let target = fan.targetRPM
                else {
                    return false
                }
                return abs(target - expected) <= 5
                    && abs(fan.actualRPM - expected)
                        <= fixture.actualRPMTolerance
            }) {
                return true
            }
            sleep(0.2)
        } while now() < deadline
        return false
    }

    private func ownershipIsIntact(_ fans: [FanTelemetry]) -> Bool {
        guard let previousDemand = lastAppliedDemand else {
            return fans.allSatisfy {
                guard let mode = try? readMode(forFan: $0.index) else {
                    return false
                }
                return mode == 0 || mode == 3
            }
        }

        return zip(fans, fixture.qualifiedRPMBounds).allSatisfy {
            fan, bounds in
            let expected = bounds.minimum
                + previousDemand * (bounds.maximum - bounds.minimum)
            guard (try? readMode(forFan: fan.index)) == 1,
                  let target = fan.targetRPM
            else {
                return false
            }
            return abs(target - expected) <= 5
                && abs(fan.actualRPM - expected)
                    <= fixture.actualRPMTolerance
        }
    }

    private func systemControlIsVerified(fanCount: Int) -> Bool {
        for index in 0..<fanCount {
            let modes = modeKeyCandidates(forFan: index).compactMap {
                try? readMode(forKey: $0)
            }
            guard !modes.isEmpty,
                  modes.allSatisfy({ $0 == 0 || $0 == 3 })
            else {
                return false
            }
        }

        if fixture.requiresFtstUnlock {
            guard readIntegerValue(forKey: "Ftst") == 0 else {
                return false
            }
        }
        return true
    }

    private func waitForSystemControl(
        fanCount: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = now().addingTimeInterval(timeout)
        repeat {
            if systemControlIsVerified(fanCount: fanCount) {
                return true
            }
            for index in 0..<fanCount {
                try? requestAutomaticMode(forFan: index)
                try? writeRPM(0, key: "F\(index)Tg")
            }
            sleep(0.1)
        } while now() < deadline
        return false
    }

    private func writeMode(_ mode: UInt8, key: String) throws {
        try writeFirstByte(mode, key: key)
    }

    private func readMode(forFan index: Int) throws -> Int {
        if let activeKey = activeModeKeys[index] {
            return try readMode(forKey: activeKey)
        }

        var firstMode: (key: String, value: Int)?
        for key in modeKeyCandidates(forFan: index) {
            guard let mode = try? readMode(forKey: key) else {
                continue
            }
            if mode == 1 {
                activeModeKeys[index] = key
                return mode
            }
            if firstMode == nil {
                firstMode = (key, mode)
            }
        }
        guard let firstMode else {
            throw FanHardwareError.invalidTelemetry
        }
        return firstMode.value
    }

    private func readMode(forKey key: String) throws -> Int {
        guard let mode = readIntegerValue(forKey: key) else {
            throw FanHardwareError.invalidTelemetry
        }
        return mode
    }

    private func modeKeyCandidates(forFan index: Int) -> [String] {
        let lowercase = "F\(index)md"
        let uppercase = "F\(index)Md"
        return switch fixture.modeKeyStyle {
        case .lowercase:
            [lowercase, uppercase]
        case .uppercase:
            [uppercase, lowercase]
        case nil:
            []
        }
    }

    private func readIntegerValue(forKey key: String) -> Int? {
        guard let value = try? smc.readValue(forKey: key)?.doubleValue,
              value.isFinite,
              value.rounded() == value,
              (0...255).contains(value)
        else {
            return nil
        }
        return Int(value)
    }

    private func writeFirstByte(_ byte: UInt8, key: String) throws {
        guard let value = try smc.readValue(forKey: key),
              !value.bytes.isEmpty
        else {
            throw FanHardwareError.invalidTelemetry
        }
        var bytes = value.bytes
        bytes[0] = byte
        try smc.writeValue(forKey: key, bytes: bytes)
    }

    private func writeRPM(_ rpm: Double, key: String) throws {
        guard let value = try smc.readValue(forKey: key) else {
            throw FanHardwareError.invalidTelemetry
        }
        try smc.writeValue(
            forKey: key,
            bytes: value.bytes(encodingRPM: rpm)
        )
    }

    private func readFanCount() throws -> Int {
        guard let value = try smc.readValue(forKey: "FNum")?.doubleValue,
              value.isFinite,
              value.rounded() == value,
              (1...8).contains(value)
        else {
            throw FanHardwareError.invalidTelemetry
        }
        return Int(value)
    }
}
