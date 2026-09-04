import Foundation

enum RemoteWorkProjectionTests {
    static func run() {
        testProjectionKeepsSessionTitlesOptInAndPseudonymous()
        testProjectionPreservesOperationalStateCounts()
        testProjectionUsesStructuredCodexFailuresAndStallHeuristics()
    }

    private static func testProjectionKeepsSessionTitlesOptInAndPseudonymous() {
        let now = Date(timeIntervalSince1970: 1_788_500_000)
        let thread = CodexThreadMirror(
            id: "thread-local-123",
            title: "Private redesign discussion",
            preview: "This must never leave the Mac by default.",
            cwd: "/private/workspace",
            projectName: "Private project",
            sectionID: "section-1",
            sectionName: "R&D",
            sectionPosition: 0,
            isPinned: false,
            isArchived: false,
            status: .running,
            latestTurnErrorCode: nil,
            updatedAt: now,
            startedAt: now.addingTimeInterval(-600),
            completedAt: nil,
            messages: []
        )

        let privateProjection = RemoteWorkProjection.make(
            sessions: [],
            codexThreads: [thread],
            includeTitles: false,
            now: now
        )
        let titledProjection = RemoteWorkProjection.make(
            sessions: [],
            codexThreads: [thread],
            includeTitles: true,
            now: now
        )

        expect(privateProjection.items.first?.title == nil, "does not share Codex titles by default")
        expect(titledProjection.items.first?.title == "Private redesign discussion", "shares a title only after opt-in")
        expect(
            !(privateProjection.items.first?.id.contains("thread-local-123") ?? true),
            "uses a pseudonymous identifier instead of the local thread ID"
        )
        expect(
            !String(describing: privateProjection).contains("workspace"),
            "does not include a path or message preview in the private projection"
        )
    }

    private static func testProjectionPreservesOperationalStateCounts() {
        let now = Date(timeIntervalSince1970: 1_788_500_000)
        let sessions = [
            session(id: "active", state: .running, now: now),
            session(id: "done", state: .finished, now: now),
            session(id: "stopped", state: .aborted, now: now)
        ]
        let projection = RemoteWorkProjection.make(
            sessions: sessions,
            codexThreads: [],
            includeTitles: false,
            now: now
        )
        let counts = Dictionary(uniqueKeysWithValues: projection.stateCounts.map { ($0.state, $0.count) })
        expect(counts[.active] == 1, "reports active work")
        expect(counts[.finished] == 1, "reports finished work separately")
        expect(counts[.stopped] == 1, "reports stopped work separately")
        expect(projection.attentionCount == 0, "does not invent an attention state from an aborted session")
    }

    private static func testProjectionUsesStructuredCodexFailuresAndStallHeuristics() {
        let now = Date(timeIntervalSince1970: 1_788_500_000)
        let threads = [
            CodexThreadMirror(
                id: "limited",
                title: "Wait for credits",
                preview: "",
                cwd: "/private/rate-limit",
                projectName: nil,
                sectionID: nil,
                sectionName: nil,
                sectionPosition: nil,
                isPinned: false,
                isArchived: false,
                status: .stopped,
                latestTurnErrorCode: "usageLimitExceeded",
                updatedAt: now.addingTimeInterval(-60),
                startedAt: now.addingTimeInterval(-600),
                completedAt: now.addingTimeInterval(-60),
                messages: []
            ),
            CodexThreadMirror(
                id: "stale",
                title: "Quiet build",
                preview: "",
                cwd: "/private/stale",
                projectName: nil,
                sectionID: nil,
                sectionName: nil,
                sectionPosition: nil,
                isPinned: false,
                isArchived: false,
                status: .running,
                latestTurnErrorCode: nil,
                updatedAt: now.addingTimeInterval(-15 * 60),
                startedAt: now.addingTimeInterval(-20 * 60),
                completedAt: nil,
                messages: []
            ),
            CodexThreadMirror(
                id: "done",
                title: "Checkout polish",
                preview: "",
                cwd: "/private/review",
                projectName: nil,
                sectionID: nil,
                sectionName: nil,
                sectionPosition: nil,
                isPinned: false,
                isArchived: false,
                status: .finished,
                latestTurnErrorCode: nil,
                updatedAt: now.addingTimeInterval(-120),
                startedAt: now.addingTimeInterval(-1_200),
                completedAt: now.addingTimeInterval(-120),
                messages: []
            )
        ]

        let projection = RemoteWorkProjection.make(
            sessions: [],
            codexThreads: threads,
            includeTitles: false,
            now: now
        )
        let counts = Dictionary(uniqueKeysWithValues: projection.stateCounts.map { ($0.state, $0.count) })
        expect(counts[.rateLimited] == 1, "maps Codex usage-limit failures to a rate-limited state")
        expect(counts[.stalled] == 1, "marks old in-progress work as stalled")
        expect(counts[.reviewReady] == 1, "treats completed Codex work as ready for review")
        expect(projection.attentionCount == 2, "counts only actionable failure and stall states as attention")
    }

    private static func session(id: String, state: OperatorSessionState, now: Date) -> OperatorSession {
        OperatorSession(
            id: id,
            harnessID: "hermes-agent",
            harnessName: "Hermes",
            state: state,
            startedAt: now.addingTimeInterval(-120),
            endedAt: state == .running ? nil : now.addingTimeInterval(-30),
            lastActivityAt: now.addingTimeInterval(-30),
            inputTokens: 0,
            outputTokens: 0,
            reasoningTokens: 0,
            cachedTokens: 0
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("Test failed: \(message)") }
    }
}
