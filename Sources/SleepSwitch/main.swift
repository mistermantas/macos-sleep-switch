import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let stateItem = NSMenuItem(title: "Sleep follows macOS settings", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Keep Awake", action: #selector(toggleKeepAwake), keyEquivalent: "")
    private let durationMenu = NSMenu(title: "Keep Awake For")
    private let agentsHeaderItem = NSMenuItem(title: "Checking agents…", action: nil, keyEquivalent: "")
    private let agentsSeparator = NSMenuItem.separator()
    private let settingsMenu = NSMenu(title: "Settings")
    private let keepDisplayAwakeItem = NSMenuItem(
        title: "Keep Display Awake",
        action: #selector(toggleKeepDisplayAwake),
        keyEquivalent: ""
    )
    private let activateOnLaunchItem = NSMenuItem(
        title: "Activate on Launch",
        action: #selector(toggleActivateOnLaunch),
        keyEquivalent: ""
    )
    private let defaultDurationMenu = NSMenu(title: "Default Duration")
    private let launchAtLoginItem = NSMenuItem(
        title: "Launch at Login",
        action: #selector(toggleLaunchAtLogin),
        keyEquivalent: ""
    )
    private let agentTracker = AgentTracker()
    private let powerAssertions = PowerAssertionController()
    private let launchAtLoginConfiguredKey = "launchAtLoginConfigured"
    private let keepDisplayAwakeKey = "keepDisplayAwake"
    private let activateOnLaunchKey = "activateOnLaunch"
    private let defaultDurationSecondsKey = "defaultDurationSeconds"
    private var awakeSession: AwakeSession?
    private var detectedAgents: [DetectedAgent] = []
    private var agentItems: [NSMenuItem] = []
    private var refreshTimer: Timer?
    private var expiryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerDefaults()
        configureStatusItem()
        configureMenu()
        enableLaunchAtLoginByDefault()

        if UserDefaults.standard.bool(forKey: activateOnLaunchKey) {
            startKeepingAwake(durationSeconds: defaultDurationSeconds)
        }

        refreshState()
        startRefreshTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        expiryTimer?.invalidate()
        refreshTimer?.invalidate()
        powerAssertions.stop()
    }

    private func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            keepDisplayAwakeKey: true,
            activateOnLaunchKey: false,
            defaultDurationSecondsKey: 0
        ])
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configureMenu() {
        menu.delegate = self
        stateItem.isEnabled = false
        agentsHeaderItem.isEnabled = false
        toggleItem.target = self

        let durationItem = NSMenuItem(title: "Keep Awake For", action: nil, keyEquivalent: "")
        durationItem.submenu = durationMenu
        configureDurationMenu()

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        configureSettingsMenu()

        let refreshItem = NSMenuItem(
            title: "Refresh Agents",
            action: #selector(refreshState),
            keyEquivalent: "r"
        )
        refreshItem.target = self

        let quitItem = NSMenuItem(
            title: "Quit Sleep Switch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        menu.addItem(stateItem)
        menu.addItem(toggleItem)
        menu.addItem(durationItem)
        menu.addItem(.separator())
        menu.addItem(agentsHeaderItem)
        menu.addItem(agentsSeparator)
        menu.addItem(settingsItem)
        menu.addItem(refreshItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
    }

    private func configureDurationMenu() {
        let indefiniteItem = NSMenuItem(
            title: "Indefinitely",
            action: #selector(startPresetDuration(_:)),
            keyEquivalent: ""
        )
        indefiniteItem.target = self
        indefiniteItem.representedObject = 0
        durationMenu.addItem(indefiniteItem)
        durationMenu.addItem(.separator())

        for seconds in AwakeTimeText.presetSeconds {
            let item = NSMenuItem(
                title: AwakeTimeText.duration(seconds: seconds),
                action: #selector(startPresetDuration(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = seconds
            durationMenu.addItem(item)
        }

        durationMenu.addItem(.separator())
        let customItem = NSMenuItem(
            title: "Custom…",
            action: #selector(startCustomDuration),
            keyEquivalent: ""
        )
        customItem.target = self
        durationMenu.addItem(customItem)
    }

    private func configureSettingsMenu() {
        keepDisplayAwakeItem.target = self
        activateOnLaunchItem.target = self
        launchAtLoginItem.target = self

        let defaultDurationItem = NSMenuItem(
            title: "Default Duration",
            action: nil,
            keyEquivalent: ""
        )
        defaultDurationItem.submenu = defaultDurationMenu
        configureDefaultDurationMenu()

        settingsMenu.addItem(keepDisplayAwakeItem)
        settingsMenu.addItem(activateOnLaunchItem)
        settingsMenu.addItem(defaultDurationItem)
        settingsMenu.addItem(.separator())
        settingsMenu.addItem(launchAtLoginItem)
    }

    private func configureDefaultDurationMenu() {
        let durations: [Int?] = [nil] + AwakeTimeText.presetSeconds.map(Optional.some)

        for durationSeconds in durations {
            let item = NSMenuItem(
                title: AwakeTimeText.duration(seconds: durationSeconds),
                action: #selector(setDefaultDuration(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = durationSeconds ?? 0
            defaultDurationMenu.addItem(item)
        }
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else {
            toggleKeepAwake()
            return
        }

        let shouldShowMenu = event.type == .rightMouseUp
            || event.modifierFlags.contains(.command)
            || event.modifierFlags.contains(.control)

        if shouldShowMenu {
            showMenu()
        } else {
            toggleKeepAwake()
        }
    }

    private func showMenu() {
        refreshState()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshState()
    }

    @objc private func refreshState() {
        if awakeSession?.hasExpired() == true {
            stopKeepingAwake()
        }

        detectedAgents = agentTracker.scan()
        updatePresentation()
        updateAgentPresentation()
        updateSettingsPresentation()
    }

    private var defaultDurationSeconds: Int? {
        let storedValue = UserDefaults.standard.integer(forKey: defaultDurationSecondsKey)
        return storedValue == 0 ? nil : storedValue
    }

    private var shouldKeepDisplayAwake: Bool {
        UserDefaults.standard.bool(forKey: keepDisplayAwakeKey)
    }

    private func updatePresentation() {
        let agentNames = detectedAgents.map(\.definition.name)
        let agentSummary = agentNames.isEmpty ? nil : agentNames.joined(separator: ", ")
        let presentation = awakePresentation

        statusItem.button?.image = NSImage(
            systemSymbolName: presentation.symbolName,
            accessibilityDescription: presentation.accessibilityDescription
        )
        statusItem.button?.toolTip = if let agentSummary {
            "\(presentation.toolTip) · \(agentSummary)"
        } else {
            presentation.toolTip
        }

        stateItem.title = presentation.stateTitle
        toggleItem.title = awakeSession == nil ? "Keep Awake" : "Stop Keeping Awake"
        updateDurationChecks()
    }

    private var awakePresentation: (
        symbolName: String,
        accessibilityDescription: String,
        toolTip: String,
        stateTitle: String
    ) {
        guard let awakeSession else {
            return (
                "cup.and.saucer",
                "Sleep Switch inactive",
                "Sleep follows macOS settings · Click to keep awake",
                "Sleep follows macOS settings"
            )
        }

        guard let remainingSeconds = awakeSession.remainingSeconds() else {
            return (
                "cup.and.saucer.fill",
                "Sleep Switch keeping this Mac awake",
                "Awake indefinitely · Click to stop",
                "Awake indefinitely"
            )
        }

        let remainingText = AwakeTimeText.remaining(seconds: remainingSeconds)
        return (
            "timer",
            "Sleep Switch keeping this Mac awake for \(remainingText)",
            "\(remainingText) · Click to stop",
            "Awake · \(remainingText)"
        )
    }

    private func updateDurationChecks() {
        let activeDuration = awakeSession.map { $0.durationSeconds ?? 0 }
        for item in durationMenu.items {
            guard let seconds = item.representedObject as? Int else { continue }
            item.state = activeDuration == seconds ? .on : .off
        }
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

    private func updateSettingsPresentation() {
        let defaults = UserDefaults.standard
        keepDisplayAwakeItem.state = shouldKeepDisplayAwake ? .on : .off
        activateOnLaunchItem.state = defaults.bool(forKey: activateOnLaunchKey) ? .on : .off

        let selectedDefault = defaults.integer(forKey: defaultDurationSecondsKey)
        for item in defaultDurationMenu.items {
            guard let seconds = item.representedObject as? Int else { continue }
            item.state = seconds == selectedDefault ? .on : .off
        }

        updateLaunchAtLoginPresentation()
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

    @objc private func toggleKeepAwake() {
        if awakeSession == nil {
            startKeepingAwake(durationSeconds: defaultDurationSeconds)
        } else {
            stopKeepingAwake()
        }
    }

    @objc private func startPresetDuration(_ sender: NSMenuItem) {
        guard let storedSeconds = sender.representedObject as? Int else { return }
        let durationSeconds = storedSeconds == 0 ? nil : storedSeconds
        startKeepingAwake(durationSeconds: durationSeconds)
    }

    @objc private func startCustomDuration() {
        guard let durationSeconds = requestCustomDuration() else { return }
        startKeepingAwake(durationSeconds: durationSeconds)
    }

    private func startKeepingAwake(durationSeconds: Int?) {
        expiryTimer?.invalidate()

        do {
            try powerAssertions.start(keepDisplayAwake: shouldKeepDisplayAwake)
            let session = AwakeSession(startedAt: Date(), durationSeconds: durationSeconds)
            awakeSession = session

            if let endDate = session.endDate {
                let timer = Timer(
                    fireAt: endDate,
                    interval: 0,
                    target: self,
                    selector: #selector(awakeSessionExpired),
                    userInfo: nil,
                    repeats: false
                )
                RunLoop.main.add(timer, forMode: .common)
                expiryTimer = timer
            }

            updatePresentation()
        } catch {
            awakeSession = nil
            presentAssertionError(error)
            updatePresentation()
        }
    }

    private func stopKeepingAwake() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        powerAssertions.stop()
        awakeSession = nil
        updatePresentation()
    }

    @objc private func awakeSessionExpired() {
        stopKeepingAwake()
    }

    private func requestCustomDuration() -> Int? {
        let alert = NSAlert()
        alert.messageText = "Keep Awake"
        alert.informativeText = "Choose a duration up to 23 hours 59 minutes."
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        let hoursField = NSTextField(string: "0")
        hoursField.alignment = .right
        hoursField.frame.size.width = 48
        let minutesField = NSTextField(string: "30")
        minutesField.alignment = .right
        minutesField.frame.size.width = 48

        let stack = NSStackView(views: [
            hoursField,
            NSTextField(labelWithString: "hours"),
            minutesField,
            NSTextField(labelWithString: "minutes")
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        alert.accessoryView = stack

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        let hours = hoursField.integerValue
        let minutes = minutesField.integerValue
        let seconds = (hours * 60 * 60) + (minutes * 60)

        guard (0...23).contains(hours),
              (0...59).contains(minutes),
              seconds > 0,
              seconds <= AwakeSession.maximumDurationSeconds else {
            NSSound.beep()
            return nil
        }
        return seconds
    }

    private func presentAssertionError(_ error: Error) {
        let alert = NSAlert(error: error)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func toggleKeepDisplayAwake() {
        let defaults = UserDefaults.standard
        let newValue = !shouldKeepDisplayAwake

        if let awakeSession {
            let previousValue = shouldKeepDisplayAwake
            do {
                try powerAssertions.start(keepDisplayAwake: newValue)
                defaults.set(newValue, forKey: keepDisplayAwakeKey)
                self.awakeSession = awakeSession
            } catch {
                do {
                    try powerAssertions.start(keepDisplayAwake: previousValue)
                } catch {
                    expiryTimer?.invalidate()
                    expiryTimer = nil
                    self.awakeSession = nil
                }
                presentAssertionError(error)
            }
        } else {
            defaults.set(newValue, forKey: keepDisplayAwakeKey)
        }

        updateSettingsPresentation()
    }

    @objc private func toggleActivateOnLaunch() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: activateOnLaunchKey), forKey: activateOnLaunchKey)
        updateSettingsPresentation()
    }

    @objc private func setDefaultDuration(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        UserDefaults.standard.set(seconds, forKey: defaultDurationSecondsKey)
        updateSettingsPresentation()
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
