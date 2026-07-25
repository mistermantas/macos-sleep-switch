import Foundation

struct AgentDefinition: Hashable {
    let id: String
    let name: String
    let executableNames: Set<String>
    let commandMarkers: [String]
    let excludedMarkers: [String]

    func matches(commandLine: String) -> Bool {
        let normalizedCommand = commandLine.lowercased()

        guard !excludedMarkers.contains(where: normalizedCommand.contains) else {
            return false
        }

        guard let executableName = executableName(in: commandLine) else {
            return false
        }

        if executableNames.contains(executableName) {
            return true
        }

        let markerLaunchers: Set<String> = [
            "agent",
            "bun",
            "deno",
            "node",
            "python",
            "python3"
        ]
        guard markerLaunchers.contains(executableName.lowercased()) else {
            return false
        }

        return commandMarkers.contains(where: normalizedCommand.contains)
    }

    private func executableName(in commandLine: String) -> String? {
        if let marker = commandLine.range(
            of: "/Contents/MacOS/",
            options: [.backwards, .caseInsensitive]
        ) {
            let executable = commandLine[marker.upperBound...]
                .prefix(while: { !$0.isWhitespace })
            return executable.isEmpty ? nil : String(executable)
        }

        guard let executable = commandLine.split(whereSeparator: \.isWhitespace).first else {
            return nil
        }
        return URL(fileURLWithPath: String(executable)).lastPathComponent
    }
}

struct DetectedAgent: Equatable {
    let definition: AgentDefinition
    let processCount: Int
}

struct AgentTracker {
    static let supportedAgents: [AgentDefinition] = [
        AgentDefinition(
            id: "codex",
            name: "Codex",
            executableNames: ["codex"],
            commandMarkers: [
                "/@openai/codex/",
                "/.codex/packages/standalone/"
            ],
            excludedMarkers: [
                "/.codex/computer-use/",
                "/frameworks/codex framework.framework/",
                "features.code_mode_host=true app-server",
                "codex-code-mode-host",
                " mcp-server",
                " completion "
            ]
        ),
        AgentDefinition(
            id: "claude-code",
            name: "Claude Code",
            executableNames: ["claude"],
            commandMarkers: [
                "/@anthropic-ai/claude-code/",
                "/.local/share/claude/versions/"
            ],
            excludedMarkers: [
                "/applications/claude.app/",
                " mcp serve"
            ]
        ),
        AgentDefinition(
            id: "opencode",
            name: "OpenCode",
            executableNames: ["opencode"],
            commandMarkers: [
                "/.opencode/bin/opencode",
                "/opencode-ai/"
            ],
            excludedMarkers: [
                ".app/contents/macos/opencode"
            ]
        ),
        AgentDefinition(
            id: "gemini-cli",
            name: "Gemini CLI",
            executableNames: ["gemini"],
            commandMarkers: [
                "/@google/gemini-cli/"
            ],
            excludedMarkers: []
        ),
        AgentDefinition(
            id: "antigravity-cli",
            name: "Antigravity CLI",
            executableNames: ["agy"],
            commandMarkers: [
                "/.gemini/antigravity-cli/"
            ],
            excludedMarkers: []
        ),
        AgentDefinition(
            id: "github-copilot",
            name: "GitHub Copilot",
            executableNames: ["copilot"],
            commandMarkers: [
                "/@github/copilot-cli/",
                "/@github/copilot/cli/"
            ],
            excludedMarkers: [
                " completion "
            ]
        ),
        AgentDefinition(
            id: "aider",
            name: "Aider",
            executableNames: ["aider", "aider-chat"],
            commandMarkers: [
                "/site-packages/aider/",
                "/aider/__main__.py"
            ],
            excludedMarkers: []
        ),
        AgentDefinition(
            id: "goose",
            name: "Goose",
            executableNames: ["goose"],
            commandMarkers: [
                "/aaif-goose/",
                "/block/goose/"
            ],
            excludedMarkers: [
                ".app/contents/macos/goose"
            ]
        ),
        AgentDefinition(
            id: "cursor-agent",
            name: "Cursor Agent",
            executableNames: ["cursor-agent"],
            commandMarkers: [
                "/cursor-agent/"
            ],
            excludedMarkers: []
        ),
        AgentDefinition(
            id: "grok-cli",
            name: "Grok CLI",
            executableNames: ["grok"],
            commandMarkers: [
                "/grok-cli/"
            ],
            excludedMarkers: []
        ),
        AgentDefinition(
            id: "amp",
            name: "Amp",
            executableNames: ["amp"],
            commandMarkers: [
                "/@sourcegraph/amp/",
                "/amp-cli/"
            ],
            excludedMarkers: []
        ),
        AgentDefinition(
            id: "factory-droid",
            name: "Factory Droid",
            executableNames: ["droid"],
            commandMarkers: [
                "/@factory-ai/droid/",
                "/factory-droid/"
            ],
            excludedMarkers: []
        ),
        AgentDefinition(
            id: "augment-code",
            name: "Augment Code",
            executableNames: ["auggie"],
            commandMarkers: [
                "/@augmentcode/auggie/"
            ],
            excludedMarkers: []
        ),
        AgentDefinition(
            id: "qwen-code",
            name: "Qwen Code",
            executableNames: ["qwen"],
            commandMarkers: [
                "/@qwen-code/qwen-code/",
                "/qwen-code/"
            ],
            excludedMarkers: []
        ),
        AgentDefinition(
            id: "pi-coding-agent",
            name: "Pi",
            executableNames: ["pi"],
            commandMarkers: [
                "/@mariozechner/pi-coding-agent/"
            ],
            excludedMarkers: []
        )
    ]

    let definitions: [AgentDefinition]

    init(definitions: [AgentDefinition] = AgentTracker.supportedAgents) {
        self.definitions = definitions
    }

    func scan() -> [DetectedAgent]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=,command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let processList = String(data: data, encoding: .utf8),
                  !processList.isEmpty else {
                return nil
            }

            return detect(in: processList, excludingPID: ProcessInfo.processInfo.processIdentifier)
        } catch {
            return nil
        }
    }

    func detect(in processList: String, excludingPID: Int32? = nil) -> [DetectedAgent] {
        var counts: [AgentDefinition: Int] = [:]

        for line in processList.split(separator: "\n") {
            guard let process = parse(line: String(line)) else { continue }
            guard process.pid != excludingPID else { continue }

            for definition in definitions where definition.matches(commandLine: process.commandLine) {
                counts[definition, default: 0] += 1
                break
            }
        }

        return definitions.compactMap { definition in
            guard let processCount = counts[definition] else { return nil }
            return DetectedAgent(definition: definition, processCount: processCount)
        }
    }

    private func parse(line: String) -> (pid: Int32, commandLine: String)? {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        guard let separator = trimmedLine.firstIndex(where: \.isWhitespace) else {
            return nil
        }

        let pidText = trimmedLine[..<separator]
        let commandLine = trimmedLine[separator...]
            .trimmingCharacters(in: .whitespaces)

        guard let pid = Int32(pidText), !commandLine.isEmpty else {
            return nil
        }

        return (pid, commandLine)
    }
}
