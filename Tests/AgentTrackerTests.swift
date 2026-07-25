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
                "cursor-agent"
            ],
            "detects the supported agent CLIs in display order"
        )
        expect(
            detected.allSatisfy { $0.processCount == 1 },
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

        if ProcessInfo.processInfo.environment["SLEEP_SWITCH_LIVE_CHECK"] == "1" {
            let liveAgents = AgentTracker().scan()
            let summary = liveAgents
                .map { "\($0.definition.name)=\($0.processCount)" }
                .joined(separator: ", ")
            print("Live agents: \(summary.isEmpty ? "none" : summary)")
        }

        print("AgentTrackerTests passed")
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
