import Foundation

enum FanHardwareFixtureTests {
    static func run() {
        let fixture = FanHardwareFixture.fixture(for: "Mac16,7")
        expect(fixture.isKnownModel, "recognizes the current M4 Pro MacBook Pro")
        expect(
            fixture.expectedFanCount == 2,
            "expects both Mac16,7 fans"
        )
        expect(
            fixture.qualification == .monitoringOnly,
            "does not write fans before hardware qualification"
        )
        expect(
            fixture.cpuTemperatureKeys.contains("Tp01")
                && fixture.gpuTemperatureKeys.contains("Tg1U"),
            "uses model-appropriate M4 Pro temperature keys"
        )

        let unknown = FanHardwareFixture.fixture(for: "Mac99,99")
        expect(!unknown.isKnownModel, "treats unknown hardware conservatively")
        expect(
            unknown.qualification == .monitoringOnly
                && unknown.expectedFanCount == nil,
            "keeps unknown hardware monitoring-only"
        )

        expect(
            SMCReadValue(
                key: "F0Ac",
                dataType: "fpe2",
                bytes: [0x3e, 0x80]
            ).doubleValue == 4_000,
            "decodes Intel fixed-point fan RPM"
        )
        var floatRPM = Float(5_250)
        let floatBytes = withUnsafeBytes(of: &floatRPM) { Array($0) }
        expect(
            SMCReadValue(
                key: "F0Ac",
                dataType: "flt ",
                bytes: floatBytes
            ).doubleValue == 5_250,
            "decodes Apple Silicon fan RPM"
        )
        expect(
            SMCReadValue(
                key: "TC0P",
                dataType: "sp78",
                bytes: [0x37, 0x80]
            ).doubleValue == 55.5,
            "decodes signed fixed-point temperature"
        )
        do {
            _ = try SMCReadValue(
                key: "F0Tg",
                dataType: "fpe2",
                bytes: [0, 0]
            ).bytes(encodingRPM: 20_000)
            fatalError(
                "Test failed: encoded an RPM that overflows fpe2"
            )
        } catch {
            expect(
                error is SMCReadError,
                "rejects an RPM that cannot be represented by fpe2"
            )
        }

        let reader = FakeSMCReader(values: [
            "FNum": value("FNum", "ui8 ", [2]),
            "F0Ac": floatValue("F0Ac", 2_100),
            "F0Mn": floatValue("F0Mn", 1_500),
            "F0Mx": floatValue("F0Mx", 6_000),
            "F0Tg": floatValue("F0Tg", 2_400),
            "F0md": value("F0md", "ui8 ", [0]),
            "F1Ac": floatValue("F1Ac", 2_200),
            "F1Mn": floatValue("F1Mn", 1_600),
            "F1Mx": floatValue("F1Mx", 5_800),
            "F1Tg": floatValue("F1Tg", 2_500),
            "F1md": value("F1md", "ui8 ", [3]),
            "Te05": floatValue("Te05", 48),
            "Te0S": floatValue("Te0S", 50),
            "Tp01": floatValue("Tp01", 58),
            "Tp05": floatValue("Tp05", 60),
            "Tg1U": floatValue("Tg1U", 52),
            "Tm0p": floatValue("Tm0p", 45)
        ])
        let now = Date(timeIntervalSince1970: 20_000)
        let snapshot = TemperatureMonitor(
            reader: reader,
            fixture: fixture
        ).snapshot(at: now)

        expect(snapshot.temperature?.cpuAverageCelsius == 54, "averages CPU sensors")
        expect(snapshot.temperature?.gpuAverageCelsius == 52, "averages GPU sensors")
        expect(snapshot.temperature?.hottestCelsius == 60, "tracks the hottest sensor")
        expect(snapshot.temperature?.aggregateCelsius == 60, "uses the safe aggregate")
        expect(
            snapshot.temperatureReadings["Te05"] == 48
                && snapshot.temperatureReadings["Tg1U"] == 52,
            "retains only vetted per-key readings for anonymized diagnostics"
        )
        expect(snapshot.fans.count == 2, "reads every reported fan")
        expect(snapshot.fans.allSatisfy(\.hasValidBounds), "validates fan bounds")
        expect(
            snapshot.diagnosticSummary.contains("model=Mac16,7")
                && snapshot.diagnosticSummary.contains("fans=[0:2100/6000,1:2200/5800]"),
            "creates a concise anonymized diagnostic"
        )
        let metadata = fixture.diagnosticMetadata(
            temperatureReadings: snapshot.temperatureReadings
        )
        expect(
            metadata.contains("mode-key-pattern=F#md")
                && metadata.contains("fan-rpm-key-patterns=F#Ac,F#Mn,F#Mx,F#Tg")
                && metadata.contains("unlock-key=Ftst")
                && metadata.contains("Te05=48.0")
                && metadata.contains("Te09=unavailable"),
            "exports fixed fixture metadata without arbitrary SMC access"
        )

        let corruptFanCountReader = FakeSMCReader(values: [
            "FNum": floatValue("FNum", Float.greatestFiniteMagnitude)
        ])
        let corruptFanSnapshot = TemperatureMonitor(
            reader: corruptFanCountReader,
            fixture: fixture
        ).snapshot(at: now)
        expect(
            corruptFanSnapshot.fans.isEmpty,
            "rejects an out-of-range fan count without converting it to Int"
        )
    }

    private static func value(
        _ key: String,
        _ dataType: String,
        _ bytes: [UInt8]
    ) -> SMCReadValue {
        SMCReadValue(key: key, dataType: dataType, bytes: bytes)
    }

    private static func floatValue(
        _ key: String,
        _ number: Float
    ) -> SMCReadValue {
        var number = number
        return value(
            key,
            "flt ",
            withUnsafeBytes(of: &number) { Array($0) }
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

private final class FakeSMCReader: SMCValueReading {
    private let values: [String: SMCReadValue]

    init(values: [String: SMCReadValue]) {
        self.values = values
    }

    func readValue(forKey key: String) throws -> SMCReadValue? {
        values[key]
    }
}
