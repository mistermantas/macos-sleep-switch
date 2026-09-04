import Foundation

/// Builds the companion’s bounded operational view from local-only Operator
/// data. The Mac remains authoritative: this projection never reads prompts,
/// transcript text, paths, artifacts, or command payloads.
enum RemoteWorkProjection {
    private static let staleRunningWindow: TimeInterval = 8 * 60

    static func make(
        sessions: [OperatorSession],
        codexThreads: [CodexThreadMirror],
        includeTitles: Bool,
        now: Date = Date(),
        maximumItems: Int = 24
    ) -> CompanionRemoteWorkSummary {
        var items: [CompanionWorkItemSummary] = []

        // The Codex desktop catalog has a more faithful status than rollout
        // files, so prefer it whenever it is readable. This also avoids
        // reporting the same Codex task twice from two local sources.
        if codexThreads.isEmpty {
            items += sessions
                .filter { $0.harnessID == "codex" }
                .map { sessionItem(from: $0, now: now) }
        } else {
            items += codexThreads.map { thread in
                CompanionWorkItemSummary(
                    id: CompanionRemoteWorkSummary.pseudonymousID(
                        harnessID: "codex",
                        localID: thread.id
                    ),
                    harnessID: "codex",
                    harnessName: "Codex",
                    state: state(for: thread, now: now),
                    startedAt: thread.startedAt ?? thread.updatedAt,
                    updatedAt: thread.completedAt ?? thread.updatedAt,
                    durationSeconds: max(
                        0,
                        (thread.completedAt ?? now).timeIntervalSince(thread.startedAt ?? thread.updatedAt)
                    ),
                    title: includeTitles ? nonEmpty(thread.title) : nil
                )
            }
        }

        items += sessions
            .filter { $0.harnessID != "codex" }
            .map { sessionItem(from: $0, now: now) }

        let ordered = items.sorted(by: order)
        let stateCounts = CompanionWorkState.allCases.compactMap { state -> CompanionWorkStateCount? in
            let count = ordered.count { $0.state == state }
            return count > 0 ? CompanionWorkStateCount(state: state, count: count) : nil
        }
        return CompanionRemoteWorkSummary(
            updatedAt: now,
            items: Array(ordered.prefix(max(1, maximumItems))),
            stateCounts: stateCounts,
            attentionCount: ordered.count { $0.state.requiresAttention }
        )
    }

    private static func sessionItem(
        from session: OperatorSession,
        now: Date
    ) -> CompanionWorkItemSummary {
        let updatedAt = session.endedAt ?? session.lastActivityAt ?? session.startedAt
        return CompanionWorkItemSummary(
            id: CompanionRemoteWorkSummary.pseudonymousID(
                harnessID: session.harnessID,
                localID: session.id
            ),
            harnessID: session.harnessID,
            harnessName: session.harnessName,
            state: state(for: session, now: now),
            startedAt: session.startedAt,
            updatedAt: updatedAt,
            durationSeconds: max(0, (session.endedAt ?? now).timeIntervalSince(session.startedAt)),
            // Local adapters deliberately do not retain titles for harnesses
            // other than the user’s explicit Codex mirror opt-in.
            title: nil
        )
    }

    private static func state(for session: OperatorSession, now: Date) -> CompanionWorkState {
        let base: CompanionWorkState = switch session.state {
        case .running: .active
        case .finished: .finished
        case .aborted: .stopped
        case .unknown: .unknown
        }
        return refinedForStall(
            base,
            lastUpdateAt: session.lastActivityAt ?? session.startedAt,
            now: now
        )
    }

    private static func state(for thread: CodexThreadMirror, now: Date) -> CompanionWorkState {
        if let errorCode = thread.latestTurnErrorCode?.lowercased() {
            if errorCode.contains("usagelimitexceeded") || errorCode.contains("rate") {
                return .rateLimited
            }
            if errorCode.contains("serveroverloaded") {
                return .waiting
            }
        }

        let lastUpdateAt = max(
            thread.messages.last?.createdAt ?? .distantPast,
            thread.completedAt ?? thread.updatedAt
        )
        let base: CompanionWorkState = switch thread.status {
        case .running: .active
        case .waiting: .waiting
        case .finished: .reviewReady
        case .stopped: thread.latestTurnErrorCode == nil ? .stopped : .failed
        case .unknown: .unknown
        }
        return refinedForStall(base, lastUpdateAt: lastUpdateAt, now: now)
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func order(_ left: CompanionWorkItemSummary, _ right: CompanionWorkItemSummary) -> Bool {
        let leftPriority = left.state.requiresAttention ? 0 : (left.state == .active ? 1 : 2)
        let rightPriority = right.state.requiresAttention ? 0 : (right.state == .active ? 1 : 2)
        if leftPriority != rightPriority { return leftPriority < rightPriority }
        return left.updatedAt > right.updatedAt
    }

    private static func refinedForStall(
        _ state: CompanionWorkState,
        lastUpdateAt: Date,
        now: Date
    ) -> CompanionWorkState {
        guard state == .active || state == .waiting else { return state }
        return now.timeIntervalSince(lastUpdateAt) >= staleRunningWindow ? .stalled : state
    }
}
