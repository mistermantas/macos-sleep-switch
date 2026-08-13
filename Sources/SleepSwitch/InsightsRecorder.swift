import Foundation
import OSLog

struct EnergyBucketAccumulator {
    let bucketStart: Date
    private(set) var readings: [EnergyReading] = []

    mutating func append(_ reading: EnergyReading) {
        readings.append(reading)
    }

    var bucket: EnergyBucket {
        let wattValues = readings.compactMap { reading -> Double? in
            guard let watts = reading.watts, watts.isFinite, watts >= 0 else {
                return nil
            }
            return watts
        }
        let averageWatts = wattValues.isEmpty
            ? nil
            : wattValues.reduce(0, +) / Double(wattValues.count)
        let peakWatts = wattValues.max()
        let source = readings
            .map(\.source)
            .max { lhs, rhs in sourceRank(lhs) < sourceRank(rhs) }
            ?? .unavailable
        let confidence: EnergyConfidence = if wattValues.isEmpty {
            EnergyConfidence.unavailable
        } else if readings.contains(where: { $0.confidence == .measured }) {
            .measured
        } else {
            .estimated
        }

        return EnergyBucket(
            bucketStart: bucketStart,
            durationSeconds: 5 * 60,
            averageWatts: averageWatts,
            peakWatts: peakWatts,
            kilowattHours: averageWatts.map { $0 * (5.0 / 60.0) / 1_000 },
            source: source,
            confidence: confidence,
            sampleCount: readings.count
        )
    }

    private func sourceRank(_ source: EnergySource) -> Int {
        switch source {
        case .battery:
            return 4
        case .ups:
            return 3
        case .ac:
            return 2
        case .unavailable:
            return 1
        }
    }
}

@MainActor
final class InsightsRecorder {
    static let historyEnabledKey = "insightsHistoryEnabled"
    static let sampleInterval: TimeInterval = 60
    static let bucketInterval: TimeInterval = 5 * 60
    private static let logger = Logger(
        subsystem: "lt.mantas.sleepswitch",
        category: "history"
    )

    let historyStore: HistoryStore?
    let powerProvider: PowerTelemetryProviding
    var onChange: ((InsightsSnapshot) -> Void)?

    private(set) var latestReading: EnergyReading?
    private(set) var liveReadings: [EnergyReading] = []
    private var currentBucket: EnergyBucketAccumulator?
    private var activeIntervals: [String: AgentActivityInterval] = [:]
    private var timer: Timer?
    private var lastPruneAt: Date?
    private(set) var lastPersistenceError: String?

    init(
        historyStore: HistoryStore? = nil,
        powerProvider: PowerTelemetryProviding = IOKitPowerTelemetryProvider()
    ) {
        self.powerProvider = powerProvider
        if let historyStore {
            self.historyStore = historyStore
        } else {
            do {
                self.historyStore = try HistoryStore()
            } catch {
                self.historyStore = nil
                self.recordPersistenceError("open", error: error)
            }
        }
        UserDefaults.standard.register(defaults: [
            Self.historyEnabledKey: true
        ])
    }

    var historyEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.historyEnabledKey)
    }

    var storageBytes: Int64 {
        historyStore?.storageBytes ?? 0
    }

    func start() {
        guard timer == nil else { return }
        sampleEnergy()
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.sampleInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sampleEnergy()
            }
        }
        timer.tolerance = 15
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        flushCurrentBucket()
    }

    func sampleEnergy(at date: Date = Date()) {
        let reading = powerProvider.read(at: date)
        latestReading = reading
        liveReadings.append(reading)
        if liveReadings.count > 24 * 60 {
            liveReadings.removeFirst(liveReadings.count - (24 * 60))
        }

        let start = bucketStart(for: date)
        if currentBucket?.bucketStart != start {
            flushCurrentBucket()
            currentBucket = EnergyBucketAccumulator(bucketStart: start)
        }
        currentBucket?.append(reading)

        if let lastPruneAt,
           date.timeIntervalSince(lastPruneAt) < 12 * 60 * 60 {
            publish()
            return
        }
        self.lastPruneAt = date
        persist("prune") { store in
            try store.prune(now: date)
        }
        publish()
    }

    func recordAgents(_ agents: [DetectedAgent], at date: Date = Date()) {
        var current: [String: DetectedAgent] = [:]
        for agent in agents {
            current[agent.definition.id] = agent
        }

        for (agentID, interval) in activeIntervals {
            guard let agent = current[agentID] else {
                let finished = AgentActivityInterval(
                    id: interval.id,
                    agentID: interval.agentID,
                    agentName: interval.agentName,
                    startedAt: interval.startedAt,
                    endedAt: date,
                    state: .finished,
                    peakSessionCount: interval.peakSessionCount
                )
                activeIntervals.removeValue(forKey: agentID)
                if historyEnabled {
                    persist("save agent interval") { store in
                        try store.saveAgentInterval(finished)
                    }
                }
                continue
            }

            guard agent.processCount != interval.peakSessionCount else {
                continue
            }
            let updated = AgentActivityInterval(
                id: interval.id,
                agentID: interval.agentID,
                agentName: interval.agentName,
                startedAt: interval.startedAt,
                endedAt: nil,
                state: .running,
                peakSessionCount: max(interval.peakSessionCount, agent.processCount)
            )
            activeIntervals[agentID] = updated
            if historyEnabled {
                persist("save agent interval") { store in
                    try store.saveAgentInterval(updated)
                }
            }
        }

        for agent in current.values where activeIntervals[agent.definition.id] == nil {
            let interval = AgentActivityInterval(
                id: UUID(),
                agentID: agent.definition.id,
                agentName: agent.definition.name,
                startedAt: date,
                endedAt: nil,
                state: .running,
                peakSessionCount: agent.processCount
            )
            activeIntervals[agent.definition.id] = interval
            if historyEnabled {
                persist("save agent interval") { store in
                    try store.saveAgentInterval(interval)
                }
            }
        }
        publish()
    }

    func setHistoryEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.historyEnabledKey)
        publish()
    }

    func deleteHistory() throws {
        do {
            try historyStore?.deleteAll()
            lastPersistenceError = nil
        } catch {
            recordPersistenceError("delete history", error: error)
            throw error
        }
        liveReadings.removeAll()
        currentBucket = nil
        publish()
    }

    func snapshot(
        for range: InsightsRange,
        now: Date = Date()
    ) -> InsightsSnapshot {
        let start = now.addingTimeInterval(-range.duration)
        let persistedBuckets = read("read energy history") { store in
            try store.energyBuckets(from: start, to: now)
        }
        let intervals = read("read agent history") { store in
            try store.agentIntervals(from: start, to: now)
        }
        let currentIntervals = activeIntervals.values.filter {
            $0.startedAt <= now && $0.effectiveEnd >= start
        }
        var allIntervals = (intervals ?? [])
        for interval in currentIntervals
            where !allIntervals.contains(where: { $0.id == interval.id }) {
            allIntervals.append(interval)
        }

        return InsightsSnapshot(
            energy: liveReadings.filter { $0.recordedAt >= start },
            buckets: persistedBuckets ?? [],
            activities: allIntervals.sorted { $0.startedAt < $1.startedAt },
            updatedAt: now,
            historyEnabled: historyEnabled,
            storageBytes: storageBytes,
            historyError: lastPersistenceError
        )
    }

    private func flushCurrentBucket() {
        guard let currentBucket, historyEnabled else {
            self.currentBucket = nil
            return
        }
        persist("save energy bucket") { store in
            try store.saveEnergy(currentBucket.bucket)
        }
        self.currentBucket = nil
    }

    private func persist(
        _ operation: String,
        _ work: (HistoryStore) throws -> Void
    ) {
        guard let historyStore else { return }
        do {
            try work(historyStore)
            lastPersistenceError = nil
        } catch {
            recordPersistenceError(operation, error: error)
        }
    }

    private func read<T>(
        _ operation: String,
        _ work: (HistoryStore) throws -> [T]
    ) -> [T]? {
        guard let historyStore else { return nil }
        do {
            return try work(historyStore)
        } catch {
            recordPersistenceError(operation, error: error)
            return nil
        }
    }

    private func recordPersistenceError(_ operation: String, error: Error) {
        let userMessage = "History is unavailable while Sleep Switch tries to \(operation)."
        lastPersistenceError = userMessage
        let details = error.localizedDescription
        Self.logger.error(
            "History \(operation) failed: \(details, privacy: .private(mask: .hash))"
        )
    }

    private func bucketStart(for date: Date) -> Date {
        let interval = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: floor(interval / Self.bucketInterval) * Self.bucketInterval)
    }

    private func publish() {
        onChange?(snapshot(for: .live))
    }
}
