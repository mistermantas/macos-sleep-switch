import AppKit
import Foundation

@main
struct AgentTrackerTests {
    static func main() {
        let fixture = """
          101 /opt/homebrew/bin/codex
          102 /Users/test/.local/share/claude/versions/2.1.0/claude
          103 /Users/test/.opencode/bin/opencode
          104 /opt/homebrew/bin/node /opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js
          105 /Users/test/.local/bin/agy
          106 /usr/local/bin/copilot
          107 /Users/test/.venv/bin/python /Users/test/.venv/lib/python3.13/site-packages/aider/main.py
          108 /opt/homebrew/bin/goose
          109 /Users/test/.local/bin/cursor-agent
          110 /Applications/ChatGPT.app/Contents/Resources/codex app-server --listen stdio://
          111 /Applications/ChatGPT.app/Contents/Resources/codex-code-mode-host
          112 /Applications/Claude.app/Contents/MacOS/Claude
          113 postgres: postgres project_codex idle
          114 /bin/zsh -lc echo codex
          115 /Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Helpers/Codex (Renderer)
          116 /Users/test/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService
          117 /Applications/ChatGPT.app/Contents/Resources/codex -c features.code_mode_host=true app-server --analytics-default-enabled
          118 /Users/test/.local/bin/grok
          119 /Users/test/.local/bin/amp
          120 /Users/test/.local/bin/droid
          121 /Users/test/.local/bin/auggie
          122 /Users/test/.local/bin/qwen
          123 /Users/test/.local/bin/pi
        """

        let detected = AgentTracker().detect(in: fixture)
        let detectedIDs = detected.map(\.definition.id)

        expect(
            detectedIDs == [
                "codex",
                "claude-code",
                "opencode",
                "gemini-cli",
                "antigravity-cli",
                "github-copilot",
                "aider",
                "goose",
                "cursor-agent",
                "grok-cli",
                "amp",
                "factory-droid",
                "augment-code",
                "qwen-code",
                "pi-coding-agent"
            ],
            "detects the supported agent CLIs in display order"
        )
        expect(
            detected.first?.processCount == 2,
            "counts Codex desktop task servers as sessions"
        )
        expect(
            detected.dropFirst().allSatisfy { $0.processCount == 1 },
            "does not count excluded desktop helpers or unrelated command text"
        )

        let duplicateFixture = """
          201 /opt/homebrew/bin/codex
          202 /Users/test/.local/bin/codex
          203 /opt/homebrew/bin/opencode
        """
        let duplicateResult = AgentTracker().detect(in: duplicateFixture)
        expect(duplicateResult[0].processCount == 2, "counts parallel sessions")
        expect(duplicateResult[1].processCount == 1, "keeps counts scoped to each agent")

        let excludedPIDResult = AgentTracker().detect(
            in: "301 /opt/homebrew/bin/codex",
            excludingPID: 301
        )
        expect(excludedPIDResult.isEmpty, "can exclude the current process")

        let unrelatedMarkerResult = AgentTracker().detect(
            in: """
              401 /usr/bin/grep /@openai/codex/
              402 /bin/zsh -lc node /@google/gemini-cli/
              403 /Applications/Claude.app/Contents/MacOS/Claude
              404 /Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Helpers/Codex (Renderer)
            """
        )
        expect(
            unrelatedMarkerResult.isEmpty,
            "requires an agent executable or supported runtime launcher"
        )

        testAwakeSession()
        testAwakePolicy(detectedAgent: detected[0])
        testDisplayWakePolicy(detectedAgent: detected[0])
        testCodexSessionTracker(
            codexAgent: detected[0],
            anotherAgent: detected[1]
        )
        testPowerAssertions()
        testDisplayPowerCommand()
        testAppLinks()
        testDistribution()
        testStatusSymbols()

        if ProcessInfo.processInfo.environment["SLEEP_SWITCH_LIVE_CHECK"] == "1" {
            let codexScanStartedAt = Date()
            let liveCodexSessions = CodexSessionTracker().scan()
            let codexScanMilliseconds = Int(
                Date().timeIntervalSince(codexScanStartedAt) * 1_000
            )
            let scanStartedAt = Date()
            let liveAgents = AgentTracker().scan() ?? []
            let summary = liveAgents
                .map { "\($0.definition.name)=\($0.processCount)" }
                .joined(separator: ", ")
            print(
                "Live Codex sessions: \(liveCodexSessions.map(String.init) ?? "unavailable")"
                    + " (\(codexScanMilliseconds)ms)"
            )
            print("Live agents: \(summary.isEmpty ? "none" : summary)")
            print(
                "Live scan: \(Int(Date().timeIntervalSince(scanStartedAt) * 1_000))ms"
            )
        }

        if ProcessInfo.processInfo.environment["SLEEP_SWITCH_DISPLAY_CHECK"] == "1" {
            testLiveDisplaySleepAndWake()
        }

        print("SleepSwitchTests passed")
    }

    private static func testAwakeSession() {
        let start = Date(timeIntervalSince1970: 1_000)
        let timedSession = AwakeSession(startedAt: start, durationSeconds: 15 * 60)

        expect(
            timedSession.remainingSeconds(at: start.addingTimeInterval(60)) == 14 * 60,
            "calculates timed-session progress"
        )
        expect(
            timedSession.hasExpired(at: start.addingTimeInterval(15 * 60)),
            "expires timed sessions at their deadline"
        )

        let indefiniteSession = AwakeSession(startedAt: start, durationSeconds: nil)
        expect(
            indefiniteSession.remainingSeconds(at: start.addingTimeInterval(99_999)) == nil,
            "keeps indefinite sessions active"
        )
        expect(
            AwakeTimeText.duration(seconds: 90 * 60) == "1h 30m",
            "formats custom durations"
        )
        expect(
            AwakeTimeText.remaining(seconds: 61) == "2m left",
            "rounds the visible countdown up"
        )
    }

    private static func testAwakePolicy(detectedAgent: DetectedAgent) {
        let manualSession = AwakeSession(startedAt: Date(), durationSeconds: nil)

        expect(
            AwakePolicy.shouldKeepAwake(
                manualSession: manualSession,
                automaticAgentAwakeEnabled: false,
                wakeWhenAgentsFinishArmed: false,
                detectedAgents: []
            ),
            "keeps manual sessions independent from agent tracking"
        )
        expect(
            AwakePolicy.shouldKeepAwake(
                manualSession: nil,
                automaticAgentAwakeEnabled: true,
                wakeWhenAgentsFinishArmed: false,
                detectedAgents: [detectedAgent]
            ),
            "keeps awake automatically while a supported agent runs"
        )
        expect(
            !AwakePolicy.shouldKeepAwake(
                manualSession: nil,
                automaticAgentAwakeEnabled: false,
                wakeWhenAgentsFinishArmed: false,
                detectedAgents: [detectedAgent]
            ),
            "lets users pause automatic agent awake"
        )
        expect(
            AwakePolicy.shouldKeepAwake(
                manualSession: nil,
                automaticAgentAwakeEnabled: false,
                wakeWhenAgentsFinishArmed: true,
                detectedAgents: []
            ),
            "keeps the Mac awake while a display wake is queued"
        )
    }

    private static func testDisplayWakePolicy(detectedAgent: DetectedAgent) {
        expect(
            !DisplayWakePolicy.shouldAttemptWake(
                isArmed: true,
                detectedAgents: [detectedAgent]
            ),
            "waits while an agent session is still running"
        )
        expect(
            DisplayWakePolicy.shouldAttemptWake(
                isArmed: true,
                detectedAgents: []
            ),
            "wakes after every detected agent session ends"
        )
        expect(
            !DisplayWakePolicy.shouldAttemptWake(
                isArmed: false,
                detectedAgents: []
            ),
            "does not wake the display unless the one-shot mode is armed"
        )
    }

    private static func testCodexSessionTracker(
        codexAgent: DetectedAgent,
        anotherAgent: DetectedAgent
    ) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "sleep-switch-codex-tracker-\(UUID().uuidString)",
            isDirectory: true
        )
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let day = sessions.appendingPathComponent("2026/07/25", isDirectory: true)
        let completedOnlySessions = root.appendingPathComponent(
            "completed-sessions",
            isDirectory: true
        )
        let fixedNow = Date(timeIntervalSince1970: 10_000)

        do {
            try fileManager.createDirectory(
                at: day,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: completedOnlySessions,
                withIntermediateDirectories: true
            )

            try write(
                """
                {"type":"event_msg","payload":{"type":"task_started"}}
                {"type":"response_item","payload":{"type":"reasoning"}}
                """,
                to: day.appendingPathComponent("rollout-active.jsonl")
            )
            try write(
                """
                {"type":"event_msg","payload":{"type":"task_started"}}
                {"type":"event_msg","payload":{"type":"task_complete"}}
                """,
                to: day.appendingPathComponent("rollout-complete.jsonl")
            )
            try write(
                """
                {"type":"event_msg","payload":{"type":"task_started"}}
                \(String(repeating: "x", count: 1_024))
                """,
                to: day.appendingPathComponent("rollout-large-active.jsonl")
            )

            let staleFile = day.appendingPathComponent("rollout-stale.jsonl")
            try write(
                """
                {"type":"event_msg","payload":{"type":"task_started"}}
                """,
                to: staleFile
            )
            try fileManager.setAttributes(
                [.modificationDate: fixedNow.addingTimeInterval(-7_200)],
                ofItemAtPath: staleFile.path
            )

            try write(
                """
                {"type":"event_msg","payload":{"type":"task_started"}}
                {"type":"event_msg","payload":{"type":"task_complete"}}
                """,
                to: completedOnlySessions.appendingPathComponent(
                    "rollout-complete.jsonl"
                )
            )
        } catch {
            fatalError("Test failed: could not create Codex session fixtures: \(error)")
        }
        defer {
            try? fileManager.removeItem(at: root)
        }

        let tracker = CodexSessionTracker(
            sessionsDirectory: sessions,
            activeFileWindow: 3_600,
            tailByteCount: 96,
            now: { fixedNow }
        )
        expect(
            tracker.scan() == 2,
            "counts active Codex turns instead of persistent task servers"
        )

        let resolvedAgents = AgentTracker(
            codexSessionTracker: tracker
        ).applyingCodexSessionActivity(
            to: [
                DetectedAgent(
                    definition: codexAgent.definition,
                    processCount: 17
                ),
                anotherAgent
            ]
        )
        expect(
            resolvedAgents.first?.definition.id == "codex"
                && resolvedAgents.first?.processCount == 2,
            "replaces persistent Codex process counts with live turn counts"
        )
        expect(
            resolvedAgents.dropFirst().first == anotherAgent,
            "keeps other agent detections unchanged"
        )

        let completedTracker = CodexSessionTracker(
            sessionsDirectory: completedOnlySessions,
            activeFileWindow: 3_600,
            now: { fixedNow }
        )
        let idleAgents = AgentTracker(
            codexSessionTracker: completedTracker
        ).applyingCodexSessionActivity(
            to: [codexAgent, anotherAgent]
        )
        expect(
            idleAgents == [anotherAgent],
            "does not treat idle Codex task servers as running sessions"
        )
    }

    private static func write(_ text: String, to fileURL: URL) throws {
        try Data(text.utf8).write(to: fileURL)
    }

    private static func testPowerAssertions() {
        let controller = PowerAssertionController()

        do {
            try controller.start(keepDisplayAwake: true)
            expect(controller.isActive, "creates a system idle-sleep assertion")
            expect(controller.isKeepingDisplayAwake, "creates an optional display assertion")
            let assertionSnapshot = currentPowerAssertions()
            expect(
                assertionSnapshot.contains("Sleep Switch is keeping this Mac awake"),
                "registers the system assertion with macOS"
            )
            expect(
                assertionSnapshot.contains("Sleep Switch is keeping the display awake"),
                "registers the display assertion with macOS"
            )
            controller.stop()
            expect(!controller.isActive, "releases the system assertion")
            expect(!controller.isKeepingDisplayAwake, "releases the display assertion")
        } catch {
            fatalError("Test failed: power assertion creation returned \(error)")
        }
    }

    private static func currentPowerAssertions() -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private static func testDisplayPowerCommand() {
        expect(
            DisplayPowerController.sleepCommand.path == "/usr/bin/pmset",
            "uses the macOS power-management command"
        )
        expect(
            DisplayPowerController.sleepArguments == ["displaysleepnow"],
            "requests display sleep without sleeping the Mac"
        )
    }

    private static func testLiveDisplaySleepAndWake() {
        let controller = DisplayPowerController()

        do {
            try controller.sleepDisplay()
            Thread.sleep(forTimeInterval: 2)
            try controller.wakeDisplay()
            print("Live display sleep/wake: passed")
        } catch {
            fatalError("Test failed: live display sleep/wake returned \(error)")
        }
    }

    private static func testAppLinks() {
        let links = AppLinks.groups.flatMap { $0 }
        expect(
            AppLinks.menuTitle == "Support & Creator",
            "uses the creator-focused support menu title"
        )
        expect(
            AppLinks.menuSymbolName == "heart",
            "uses a heart for the support menu"
        )
        expect(links.count == 4, "keeps the support menu concise")
        expect(
            links.allSatisfy { $0.url.scheme == "https" },
            "opens every external link over HTTPS"
        )
        expect(
            AppLinks.uncascadeWebsite.url.absoluteString
                == "https://www.uncascade.com/",
            "links to the Uncascade website"
        )
        expect(
            AppLinks.uncascadeYouTube.url.absoluteString
                == "https://www.youtube.com/@uncascade",
            "links to the Uncascade YouTube channel"
        )
        expect(
            AppLinks.sourceCode.url.absoluteString
                == "https://github.com/mistermantas/macos-sleep-switch",
            "links to the Sleep Switch source"
        )
        expect(
            AppLinks.sponsor.url.absoluteString
                == "https://github.com/sponsors/mistermantas",
            "uses GitHub's canonical Sponsors URL"
        )
    }

    private static func testDistribution() {
        expect(!AppDistribution.isAppStoreBuild, "tests the direct distribution")
        expect(
            AppDistribution.supportsGlobalAgentTracking,
            "keeps global agent tracking in the direct build"
        )
        expect(
            AppDistribution.supportsDisplaySleep,
            "keeps display sleep in the direct build"
        )
    }

    private static func testStatusSymbols() {
        for symbolName in [
            "cup.and.saucer",
            "cup.and.saucer.fill",
            "timer",
            "terminal.fill",
            "moon.zzz",
            "moon.zzz.fill",
            "display",
            "stop.circle",
            "gearshape",
            "arrow.clockwise",
            "globe",
            "play.rectangle",
            "chevron.left.forwardslash.chevron.right",
            "heart",
            "exclamationmark.triangle"
        ] {
            expect(
                NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) != nil,
                "provides the \(symbolName) menu-bar symbol"
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
