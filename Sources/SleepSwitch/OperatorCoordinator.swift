import Foundation

struct OperatorRefreshResult: Equatable {
    let refreshedAt: Date
    let adapters: [OperatorAdapterSnapshot]
    let codexMirror: CodexMirrorSnapshot
    let indexedSkillCount: Int
    let persistenceError: String?
}

/// Serial, local-only ingestion boundary for the menu-bar app. Call this from
/// a background queue; it deliberately performs no CloudKit work and never
/// gives raw harness records to the UI layer.
final class OperatorCoordinator {
    private let store: OperatorStore?
    private let codexSessionsDirectory: () -> URL?
    private let codexRootDirectory: () -> URL?
    private let hermesDatabaseURL: () -> URL
    private let skillSources: () -> [OperatorSkillIndexer.Source]
    private let now: () -> Date

    init(
        store: OperatorStore? = try? OperatorStore(),
        codexSessionsDirectory: @escaping () -> URL? = {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions", isDirectory: true)
        },
        codexRootDirectory: @escaping () -> URL? = {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        },
        hermesDatabaseURL: @escaping () -> URL = {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".hermes/state.db")
        },
        skillSources: @escaping () -> [OperatorSkillIndexer.Source] = {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return [
                .init(url: home.appendingPathComponent(".codex/skills", isDirectory: true), label: "Codex"),
                .init(url: home.appendingPathComponent(".agents/skills", isDirectory: true), label: "Agents")
            ]
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.codexSessionsDirectory = codexSessionsDirectory
        self.codexRootDirectory = codexRootDirectory
        self.hermesDatabaseURL = hermesDatabaseURL
        self.skillSources = skillSources
        self.now = now
    }

    func refresh() -> OperatorRefreshResult {
        let refreshedAt = now()
        guard let store else {
            return OperatorRefreshResult(
                refreshedAt: refreshedAt,
                adapters: [],
                codexMirror: .unavailable,
                indexedSkillCount: 0,
                persistenceError: "Operator’s local database is unavailable."
            )
        }

        let codex = codexSessionsDirectory().map {
            CodexOperatorAdapter(sessionsDirectory: $0, now: now).snapshot()
        } ?? OperatorAdapterSnapshot(
            harnessID: "codex",
            harnessName: "Codex",
            availability: .permissionRequired,
            refreshedAt: refreshedAt,
            capabilities: [
                HarnessCapability(harnessID: "codex", kind: .sessions, isSupported: true),
                HarnessCapability(harnessID: "codex", kind: .sessionHistory, isSupported: true),
                HarnessCapability(harnessID: "codex", kind: .tokenUsage, isSupported: true)
            ],
            sessions: [],
            events: []
        )
        let hermes = HermesOperatorAdapter(
            databaseURL: hermesDatabaseURL(),
            now: now
        ).snapshot()
        let adapterSnapshots = [codex, hermes]
        let codexRoot = codexRootDirectory()
        let codexMirror = codexRoot.map {
            CodexThreadMirrorAdapter(
                stateDatabaseURL: $0.appendingPathComponent("state_5.sqlite"),
                historyDatabaseURL: $0.appendingPathComponent("thread_history_1.sqlite")
            ).snapshot()
        } ?? .unavailable
        let skills = OperatorSkillIndexer(sources: skillSources()).index()

        do {
            for snapshot in adapterSnapshots { try store.ingest(snapshot) }
            try store.upsertSkills(skills)
            return OperatorRefreshResult(
                refreshedAt: refreshedAt,
                adapters: adapterSnapshots,
                codexMirror: codexMirror,
                indexedSkillCount: skills.count,
                persistenceError: nil
            )
        } catch {
            return OperatorRefreshResult(
                refreshedAt: refreshedAt,
                adapters: adapterSnapshots,
                codexMirror: codexMirror,
                indexedSkillCount: skills.count,
                persistenceError: error.localizedDescription
            )
        }
    }

    func sessions(limit: Int = 200) -> [OperatorSession] {
        (try? store?.sessions(limit: limit)) ?? []
    }

    func skills() -> [OperatorSkillRecord] {
        (try? store?.skillRecords()) ?? []
    }

    func setFavourite(_ favourite: Bool, skillID: String) throws {
        try store?.setFavourite(favourite, for: skillID)
    }

    func replaceTags(_ tags: [String], skillID: String) throws {
        try store?.replaceTags(tags, for: skillID)
    }

    func recordSkillUse(_ event: SkillUseEvent) throws {
        try store?.recordSkillUse(event)
    }

    func threadWorkflowLanes() -> [String: String] {
        (try? store?.threadWorkflowLanes()) ?? [:]
    }

    func setThreadWorkflowLane(_ lane: String, threadID: String) throws {
        try store?.setThreadWorkflowLane(lane, threadID: threadID)
    }

    func moveCodexThread(_ threadID: String, toSectionID sectionID: String?) throws {
        let root = codexRootDirectory() ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        try CodexThreadSectionController(
            stateDatabaseURL: root.appendingPathComponent("state_5.sqlite")
        ).move(threadID: threadID, toSectionID: sectionID)
    }

    func companionSummary(
        finishAction: CompanionRemoteAction?,
        alerts: [String] = []
    ) -> CompanionOperatorSummary {
        let running = sessions().filter { $0.state == .running }
        let grouped = Dictionary(grouping: running, by: \ .harnessID)
        let harnesses = grouped.compactMap { harnessID, sessions -> CompanionOperatorHarnessSummary? in
            guard let first = sessions.first else { return nil }
            return CompanionOperatorHarnessSummary(
                harnessID: harnessID,
                harnessName: first.harnessName,
                liveSessionCount: sessions.count,
                tokenDelta: sessions.reduce(0) { $0 + $1.totalTokens },
                durationDeltaSeconds: sessions.reduce(0) { $0 + $1.durationSeconds }
            )
        }
        .sorted { $0.harnessName.localizedCaseInsensitiveCompare($1.harnessName) == .orderedAscending }
        return CompanionOperatorSummary(
            updatedAt: now(),
            harnesses: harnesses,
            activeSessionCount: running.count,
            tokenDelta: harnesses.reduce(0) { $0 + $1.tokenDelta },
            durationDeltaSeconds: harnesses.reduce(0) { $0 + $1.durationDeltaSeconds },
            finishAction: finishAction?.rawValue,
            alertCodes: Array(Set(alerts)).sorted()
        )
    }
}
