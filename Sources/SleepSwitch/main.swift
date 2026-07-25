import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let stateItem = NSMenuItem(title: "Checking sleep setting…", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Toggle", action: #selector(toggleSleepPrevention), keyEquivalent: "")
    private let agentsHeaderItem = NSMenuItem(title: "Checking agents…", action: nil, keyEquivalent: "")
    private let agentsSeparator = NSMenuItem.separator()
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let agentTracker = AgentTracker()
    private let launchAtLoginConfiguredKey = "launchAtLoginConfigured"
    private var sleepPreventionEnabled = false
    private var detectedAgents: [DetectedAgent] = []
    private var agentItems: [NSMenuItem] = []
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        enableLaunchAtLoginByDefault()
        refreshState()
        startRefreshTimer()
    }

    private func configureMenu() {
        menu.delegate = self
        stateItem.isEnabled = false
        agentsHeaderItem.isEnabled = false
        toggleItem.target = self
        launchAtLoginItem.target = self

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshState), keyEquivalent: "r")
        refreshItem.target = self

        let quitItem = NSMenuItem(title: "Quit Sleep Switch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(toggleItem)
        menu.addItem(.separator())
        menu.addItem(agentsHeaderItem)
        menu.addItem(agentsSeparator)
        menu.addItem(launchAtLoginItem)
        menu.addItem(refreshItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshState()
    }

    @objc private func refreshState() {
        sleepPreventionEnabled = readSleepPreventionState()
        detectedAgents = agentTracker.scan()
        updatePresentation()
        updateAgentPresentation()
        updateLaunchAtLoginPresentation()
    }

    private func readSleepPreventionState() -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return false }

            let values = text
                .split(separator: "\n")
                .compactMap { line -> Int? in
                    let parts = line.split(whereSeparator: \.isWhitespace)
                    guard parts.count >= 2 else { return nil }
                    let key = parts[0].lowercased()
                    guard key == "sleepdisabled" || key == "disablesleep" else {
                        return nil
                    }
                    guard let value = parts.last else { return nil }
                    return Int(value)
                }

            return values.contains(1)
        } catch {
            return false
        }
    }

    private func updatePresentation() {
        let symbolName = sleepPreventionEnabled ? "moon.fill" : "moon.zzz"
        let agentNames = detectedAgents.map(\.definition.name)
        let agentSummary = agentNames.isEmpty ? nil : agentNames.joined(separator: ", ")

        statusItem.button?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: sleepPreventionEnabled ? "Sleep prevention on" : "Sleep allowed"
        )
        statusItem.button?.toolTip = if let agentSummary {
            sleepPreventionEnabled
                ? "Sleep Switch: staying awake · \(agentSummary)"
                : "Sleep Switch: sleep allowed · \(agentSummary)"
        } else {
            sleepPreventionEnabled ? "Sleep Switch: staying awake" : "Sleep Switch: sleep allowed"
        }

        if sleepPreventionEnabled {
            stateItem.title = "Mac will stay awake"
        } else if let firstAgent = agentNames.first {
            stateItem.title = agentNames.count == 1
                ? "Sleep allowed · \(firstAgent) running"
                : "Sleep allowed · \(agentNames.count) agents running"
        } else {
            stateItem.title = "Sleep is allowed"
        }

        toggleItem.title = sleepPreventionEnabled ? "Allow sleep" : "Prevent sleep"
    }

    private func updateAgentPresentation() {
        agentItems.forEach(menu.removeItem)
        agentItems.removeAll()

        let sessionCount = detectedAgents.reduce(0) { $0 + $1.processCount }
        if sessionCount == 0 {
            agentsHeaderItem.title = "No agent sessions running"
            agentsHeaderItem.image = NSImage(
                systemSymbolName: "terminal",
                accessibilityDescription: "No agent sessions running"
            )
            return
        }

        agentsHeaderItem.title = sessionCount == 1
            ? "1 agent session running"
            : "\(sessionCount) agent sessions running"
        agentsHeaderItem.image = NSImage(
            systemSymbolName: "terminal.fill",
            accessibilityDescription: "\(sessionCount) agent sessions running"
        )

        guard let separatorIndex = menu.items.firstIndex(of: agentsSeparator) else {
            return
        }

        for (offset, agent) in detectedAgents.enumerated() {
            let suffix = agent.processCount == 1 ? "" : " · \(agent.processCount)"
            let item = NSMenuItem(
                title: "\(agent.definition.name)\(suffix)",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            item.indentationLevel = 1
            item.image = NSImage(
                systemSymbolName: "circle.fill",
                accessibilityDescription: "\(agent.definition.name) running"
            )
            agentItems.append(item)
            menu.insertItem(item, at: separatorIndex + offset)
        }
    }

    private func startRefreshTimer() {
        let timer = Timer.scheduledTimer(
            timeInterval: 5,
            target: self,
            selector: #selector(refreshState),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 1
        refreshTimer = timer
    }

    @objc private func toggleSleepPrevention() {
        let newValue = sleepPreventionEnabled ? 0 : 1
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(newValue)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                refreshState()
            }
        } catch {
            NSSound.beep()
        }
    }

    private func enableLaunchAtLoginByDefault() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: launchAtLoginConfiguredKey) else { return }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { return }

        do {
            if SMAppService.mainApp.status == .notRegistered {
                try SMAppService.mainApp.register()
            }
            defaults.set(true, forKey: launchAtLoginConfiguredKey)
        } catch {
            // Leave the preference unset so the app can try again on its next launch.
        }
    }

    private func updateLaunchAtLoginPresentation() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginItem.state = .on
        case .requiresApproval:
            launchAtLoginItem.state = .mixed
        default:
            launchAtLoginItem.state = .off
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            UserDefaults.standard.set(true, forKey: launchAtLoginConfiguredKey)
            updateLaunchAtLoginPresentation()
        } catch {
            NSSound.beep()
        }
    }
}

@main
@MainActor
struct SleepSwitchApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
