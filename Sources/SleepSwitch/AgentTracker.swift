import Darwin
import Foundation

struct AgentDefinition: Hashable {
    let id: String
    let name: String
    let executableNames: Set<String>
    let commandMarkers: [String]
    let excludedMarkers: [String]

    func matches(commandLine: String) -> Bool {
        guard let executableName = Self.executableName(in: commandLine) else {
            return false
        }
        return matches(
            executableName: executableName,
            normalizedCommand: commandLine.lowercased()
        )
    }

    func matches(executableName: String, normalizedCommand: String) -> Bool {
        guard !excludedMarkers.contains(where: normalizedCommand.contains) else {
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

    static func executableName(in commandLine: String) -> String? {
        if let marker = commandLine.range(
            of: "/Contents/MacOS/",
            options: [.backwards, .caseInsensitive]
        ) {
            let executable = commandLine[marker.upperBound...]
                .prefix(while: { !$0.isWhitespace })
            return executable.isEmpty ? nil : String(executable).lowercased()
        }

        guard let executable = commandLine.split(whereSeparator: \.isWhitespace).first else {
            return nil
        }
        return URL(fileURLWithPath: String(executable))
            .lastPathComponent
            .lowercased()
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
    let codexSessionTracker: CodexSessionTracker
    let codexSessionsDirectory: (() -> URL?)?

    init(
        definitions: [AgentDefinition] = AgentTracker.supportedAgents,
        codexSessionTracker: CodexSessionTracker = CodexSessionTracker(),
        codexSessionsDirectory: (() -> URL?)? = nil
    ) {
        self.definitions = definitions
        self.codexSessionTracker = codexSessionTracker
        self.codexSessionsDirectory = codexSessionsDirectory
    }

    func scan() -> [DetectedAgent]? {
#if APP_STORE
        // App Sandbox blocks launching `/bin/ps`, but libproc still provides a
        // read-only view of executable paths. This keeps direct agent CLIs
        // such as OpenCode discoverable without asking for broad file access.
        let processAgents = NativeProcessSnapshotProvider().processList()
            .map {
                detect(
                    in: $0,
                    excludingPID: ProcessInfo.processInfo.processIdentifier
                )
            } ?? []

        guard let sessionsDirectory = codexSessionsDirectory?() else {
            return normalizedDesktopCodexFallback(processAgents)
        }

        return applyingCodexSessionActivity(
            to: processAgents,
            tracker: CodexSessionTracker(sessionsDirectory: sessionsDirectory),
            preserveProcessFallback: true
        )
#else
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

            let processAgents = detect(
                in: processList,
                excludingPID: ProcessInfo.processInfo.processIdentifier
            )
            return applyingCodexSessionActivity(to: processAgents)
        } catch {
            return nil
        }
#endif
    }

    func detect(in processList: String, excludingPID: Int32? = nil) -> [DetectedAgent] {
        var counts: [AgentDefinition: Int] = [:]

        for line in processList.split(separator: "\n") {
            guard let process = parse(line: String(line)) else { continue }
            guard process.pid != excludingPID else { continue }
            let normalizedCommand = process.commandLine.lowercased()
            guard let executableName = AgentDefinition.executableName(
                in: process.commandLine
            ) else {
                continue
            }

            for definition in definitions where definition.matches(
                executableName: executableName,
                normalizedCommand: normalizedCommand
            ) {
                counts[definition, default: 0] += 1
                break
            }
        }

        return definitions.compactMap { definition in
            guard let processCount = counts[definition] else { return nil }
            return DetectedAgent(definition: definition, processCount: processCount)
        }
    }

    func applyingCodexSessionActivity(
        to processAgents: [DetectedAgent],
        tracker: CodexSessionTracker? = nil,
        preserveProcessFallback: Bool = false
    ) -> [DetectedAgent] {
        // Codex Desktop keeps its task work in the session log while its
        // long-lived `app-server` process is deliberately excluded from the
        // generic process detector. Do not require a separate `codex` CLI
        // process before consulting the session tracker, or Desktop tasks
        // will always appear idle.
        guard let activeSessionCount = (tracker ?? codexSessionTracker).scan() else {
            return processAgents
        }

        return definitions.compactMap { definition in
            if definition.id == "codex" {
                if activeSessionCount == 0, preserveProcessFallback {
                    return normalizedDesktopCodexFallback(processAgents).first {
                        $0.definition.id == definition.id
                    }
                }
                guard activeSessionCount > 0 else { return nil }
                return DetectedAgent(
                    definition: definition,
                    processCount: activeSessionCount
                )
            }

            return processAgents.first {
                $0.definition.id == definition.id
            }
        }
    }

    private func normalizedDesktopCodexFallback(
        _ processAgents: [DetectedAgent]
    ) -> [DetectedAgent] {
        processAgents.map { agent in
            guard agent.definition.id == "codex" else { return agent }
            // ChatGPT can own several persistent app-server helpers. Without
            // access to its session folder, represent the desktop app as one
            // active Codex source instead of claiming every helper is a task.
            return DetectedAgent(definition: agent.definition, processCount: 1)
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

private struct NativeProcessSnapshotProvider {
    func processList() -> String? {
        var capacity = 1_024

        while capacity <= 65_536 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let byteCount = Int32(MemoryLayout<pid_t>.stride * pids.count)
            let count = proc_listallpids(&pids, byteCount)
            guard count >= 0 else { return nil }

            if count < capacity {
                let lines = pids.prefix(Int(count)).compactMap { pid -> String? in
                    guard pid > 0, let path = executablePath(for: pid) else {
                        return nil
                    }
                    return "\(pid) \(path)"
                }
                return lines.isEmpty ? nil : lines.joined(separator: "\n")
            }
            capacity *= 2
        }

        return nil
    }

    private func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN * 4))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
