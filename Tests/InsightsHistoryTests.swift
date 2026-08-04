import Foundation

enum InsightsHistoryTests {
    @MainActor
    static func run() {
        testBucketAggregation()
        testStoreRoundTripAndDelete()
        testStorePruning()
        testHistoryOptOut()
        testOvernightWindow()
    }

    private static func testBucketAggregation() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var accumulator = EnergyBucketAccumulator(bucketStart: start)
        accumulator.append(EnergyReading(
            recordedAt: start,
            watts: 20,
            source: .battery,
            confidence: .estimated,
            batteryPercent: 80,
            isCharging: false
        ))
        accumulator.append(EnergyReading(
            recordedAt: start.addingTimeInterval(60),
            watts: 40,
            source: .battery,
            confidence: .estimated,
            batteryPercent: 79,
            isCharging: false
        ))

        let bucket = accumulator.bucket
        expect(bucket.sampleCount == 2, "aggregates the sample count")
        expect(bucket.averageWatts == 30, "calculates average watts")
        expect(bucket.peakWatts == 40, "keeps peak watts")
        expect(bucket.confidence == .estimated, "preserves estimated confidence")
        expect(
            EnergyReading(
                recordedAt: start,
                watts: 40,
                source: .battery,
                confidence: .estimated,
                batteryPercent: 80,
                isCharging: false
            ).displayWatts == "40 W",
            "formats the latest wattage without placeholder punctuation"
        )
        expect(
            abs((bucket.kilowattHours ?? 0) - 0.0025) < 0.000_001,
            "calculates five-minute kWh from the average"
        )
    }

    private static func testStoreRoundTripAndDelete() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleep-switch-history-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = root.appendingPathComponent("History.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let store = try HistoryStore(databaseURL: databaseURL)
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            try store.saveEnergy(EnergyBucket(
                bucketStart: date,
                durationSeconds: 300,
                averageWatts: 25,
                peakWatts: 30,
                kilowattHours: 0.002,
                source: .battery,
                confidence: .estimated,
                sampleCount: 5
            ))
            let interval = AgentActivityInterval(
                id: UUID(),
                agentID: "codex",
                agentName: "Codex",
                startedAt: date,
                endedAt: date.addingTimeInterval(300),
                state: .finished,
                peakSessionCount: 2
            )
            try store.saveAgentInterval(interval)

            let buckets = try store.energyBuckets(
                from: date.addingTimeInterval(-1),
                to: date.addingTimeInterval(1)
            )
            let intervals = try store.agentIntervals(
                from: date.addingTimeInterval(-1),
                to: date.addingTimeInterval(301)
            )
            expect(buckets.count == 1, "round-trips one energy bucket")
            expect(intervals == [interval], "round-trips one agent interval")

            try store.deleteAll()
            let deletedBuckets = try store.energyBuckets(
                from: date.addingTimeInterval(-1),
                to: date.addingTimeInterval(1)
            )
            let deletedIntervals = try store.agentIntervals(
                from: date.addingTimeInterval(-1),
                to: date.addingTimeInterval(301)
            )
            expect(deletedBuckets.isEmpty, "deletes energy history")
            expect(deletedIntervals.isEmpty, "deletes agent history")
        } catch {
            expect(false, "history store round trip failed: \(error)")
        }
    }

    private static func testStorePruning() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleep-switch-prune-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = root.appendingPathComponent("History.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let store = try HistoryStore(databaseURL: databaseURL)
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let old = now.addingTimeInterval(-(HistoryStore.defaultRawRetention + 1))
            try store.saveEnergy(EnergyBucket(
                bucketStart: old,
                durationSeconds: 300,
                averageWatts: 10,
                peakWatts: 10,
                kilowattHours: 0.001,
                source: .battery,
                confidence: .estimated,
                sampleCount: 1
            ))
            try store.saveEnergy(EnergyBucket(
                bucketStart: now,
                durationSeconds: 300,
                averageWatts: 10,
                peakWatts: 10,
                kilowattHours: 0.001,
                source: .battery,
                confidence: .estimated,
                sampleCount: 1
            ))
            try store.prune(now: now)
            let buckets = try store.energyBuckets(
                from: old.addingTimeInterval(-1),
                to: now.addingTimeInterval(1)
            )
            expect(buckets.count == 1, "prunes raw buckets outside the retention window")
            expect(buckets.first?.bucketStart == now, "keeps the current bucket")
        } catch {
            expect(false, "history pruning failed: \(error)")
        }
    }

    @MainActor
    private static func testHistoryOptOut() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sleep-switch-opt-out-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = root.appendingPathComponent("History.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }

        let previousValue = UserDefaults.standard.object(forKey: InsightsRecorder.historyEnabledKey)
        defer {
            if let previousValue {
                UserDefaults.standard.set(previousValue, forKey: InsightsRecorder.historyEnabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: InsightsRecorder.historyEnabledKey)
            }
        }

        do {
            let store = try HistoryStore(databaseURL: databaseURL)
            let recorder = InsightsRecorder(
                historyStore: store,
                powerProvider: FixturePowerTelemetryProvider(reading: EnergyReading(
                    recordedAt: Date(),
                    watts: 25,
                    source: .ac,
                    confidence: .estimated,
                    batteryPercent: nil,
                    isCharging: false
                ))
            )
            recorder.setHistoryEnabled(false)
            recorder.recordAgents([], at: Date())
            recorder.sampleEnergy(at: Date(timeIntervalSince1970: 1_700_000_000))
            recorder.stop()
            let buckets = try store.energyBuckets(
                from: Date(timeIntervalSince1970: 1_699_999_999),
                to: Date(timeIntervalSince1970: 1_700_000_301)
            )
            expect(buckets.isEmpty, "does not write energy history when saving is disabled")
        } catch {
            expect(false, "history opt-out failed: \(error)")
        }
    }

    private static func testOvernightWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let evening = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: day)!
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
        let morning = calendar.date(bySettingHour: 2, minute: 0, second: 0, of: nextDay)!
        let daytime = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: day)!

        let intervals = [
            AgentActivityInterval(
                id: UUID(), agentID: "evening", agentName: "Evening", startedAt: evening,
                endedAt: evening.addingTimeInterval(600), state: .finished, peakSessionCount: 1
            ),
            AgentActivityInterval(
                id: UUID(), agentID: "morning", agentName: "Morning", startedAt: morning,
                endedAt: morning.addingTimeInterval(600), state: .finished, peakSessionCount: 1
            ),
            AgentActivityInterval(
                id: UUID(), agentID: "day", agentName: "Day", startedAt: daytime,
                endedAt: daytime.addingTimeInterval(600), state: .finished, peakSessionCount: 1
            )
        ]
        let overnight = AgentActivityWindow.overnight(intervals, calendar: calendar)
        expect(
            overnight.map(\.agentID) == ["evening", "morning"],
            "filters activity to the local overnight window"
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
