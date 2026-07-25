import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let stateItem = NSMenuItem(title: "Sleep follows macOS settings", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Keep Awake", action: #selector(toggleKeepAwake), keyEquivalent: "")
    private let durationMenu = NSMenu(title: "Keep Awake For")
    private let automaticAgentAwakeItem = NSMenuItem(
        title: "Keep Awake for Agents",
        action: #selector(toggleAutomaticAgentAwake),
        keyEquivalent: ""
    )
    private let agentsHeaderItem = NSMenuItem(title: "Checking agents…", action: nil, keyEquivalent: "")
    private let agentsSeparator = NSMenuItem.separator()
    private let settingsMenu = NSMenu(title: "Settings")
    private let keepDisplayAwakeItem = NSMenuItem(
        title: "Manual Sessions Keep Display Awake",
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
    private let automaticAgentAwakeKey = "automaticAgentAwake"
    private var manualAwakeSession: AwakeSession?
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
            defaultDurationSecondsKey: 0,
            automaticAgentAwakeKey: true
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
        automaticAgentAwakeItem.target = self

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
        menu.addItem(automaticAgentAwakeItem)
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
        if manualAwakeSession?.hasExpired() == true {
            clearManualAwakeSession()
        }

        if let latestAgents = agentTracker.scan() {
            detectedAgents = latestAgents
        }
        _ = reconcilePowerAssertion()
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

    private var automaticAgentAwakeEnabled: Bool {
        UserDefaults.standard.bool(forKey: automaticAgentAwakeKey)
    }

    private var shouldKeepDisplayAwakeNow: Bool {
        manualAwakeSession != nil && shouldKeepDisplayAwake
    }

    private var agentAwakeRequested: Bool {
        automaticAgentAwakeEnabled && !detectedAgents.isEmpty
    }

    private var shouldKeepAwake: Bool {
        AwakePolicy.shouldKeepAwake(
            manualSession: manualAwakeSession,
            automaticAgentAwakeEnabled: automaticAgentAwakeEnabled,
            detectedAgents: detectedAgents
        )
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
        toggleItem.title = manualAwakeSession == nil
            ? "Keep Awake Manually"
            : "Stop Manual Session"
        updateDurationChecks()
    }

    private var awakePresentation: (
        symbolName: String,
        accessibilityDescription: String,
        toolTip: String,
        stateTitle: String
    ) {
        if let manualAwakeSession {
            guard let remainingSeconds = manualAwakeSession.remainingSeconds() else {
                return (
                    "cup.and.saucer.fill",
                    "Sleep Switch keeping this Mac awake manually",
                    "Awake manually · Click to stop the manual session",
                    "Awake · Manual"
                )
            }

            let remainingText = AwakeTimeText.remaining(seconds: remainingSeconds)
            return (
                "timer",
                "Sleep Switch keeping this Mac awake for \(remainingText)",
                "\(remainingText) · Click to stop the manual session",
                "Awake · \(remainingText)"
            )
        }

        if agentAwakeRequested && powerAssertions.isActive {
            let agentName = detectedAgents.count == 1
                ? detectedAgents[0].definition.name
                : "\(detectedAgents.count) agents"
            return (
                "terminal.fill",
                "Sleep Switch keeping this Mac awake for \(agentName)",
                "Awake for \(agentName) · Click for a manual session",
                "Awake · \(agentName)"
            )
        }

        if agentAwakeRequested {
            return (
                "exclamationmark.triangle",
                "Sleep Switch could not keep this Mac awake",
                "An agent is running, but the awake assertion is unavailable",
                "Agent detected · Awake unavailable"
            )
        }

        return (
            "cup.and.saucer",
            "Sleep Switch inactive",
            "Sleep follows macOS settings · Click for a manual session",
            "Sleep follows macOS settings"
        )
    }

    private func updateDurationChecks() {
        let activeDuration = manualAwakeSession.map { $0.durationSeconds ?? 0 }
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
            agentsHeaderItem.title = "No supported agents running"
            agentsHeaderItem.image = NSImage(
                systemSymbolName: "terminal",
                accessibilityDescription: "No supported agents running"
            )
            return
        }

        if detectedAgents.count == 1, let agent = detectedAgents.first {
            let sessionText = agent.processCount == 1 ? "1 session" : "\(agent.processCount) sessions"
            agentsHeaderItem.title = "\(agent.definition.name) · \(sessionText)"
        } else {
            agentsHeaderItem.title = "\(detectedAgents.count) agents · \(sessionCount) sessions"
        }
        agentsHeaderItem.image = NSImage(
            systemSymbolName: "terminal.fill",
            accessibilityDescription: "\(sessionCount) agent sessions running"
        )

        guard detectedAgents.count > 1 else {
            return
        }

        guard let separatorIndex = menu.items.firstIndex(of: agentsSeparator) else {
            return
        }

        for (offset, agent) in detectedAgents.enumerated() {
            let sessionText = agent.processCount == 1 ? "1 session" : "\(agent.processCount) sessions"
            let item = NSMenuItem(
                title: "\(agent.definition.name) · \(sessionText)",
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
        automaticAgentAwakeItem.state = automaticAgentAwakeEnabled ? .on : .off
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
        if manualAwakeSession == nil {
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

        let session = AwakeSession(startedAt: Date(), durationSeconds: durationSeconds)
        manualAwakeSession = session

        if let error = reconcilePowerAssertion() {
            manualAwakeSession = nil
            presentAssertionError(error)
            updatePresentation()
            return
        }

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
    }

    private func stopKeepingAwake() {
        clearManualAwakeSession()
        _ = reconcilePowerAssertion()
        updatePresentation()
    }

    private func clearManualAwakeSession() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        manualAwakeSession = nil
    }

    @objc private func awakeSessionExpired() {
        stopKeepingAwake()
    }

    @discardableResult
    private func reconcilePowerAssertion(forceRestart: Bool = false) -> Error? {
        guard shouldKeepAwake else {
            powerAssertions.stop()
            return nil
        }

        if powerAssertions.isActive,
           powerAssertions.isKeepingDisplayAwake == shouldKeepDisplayAwakeNow,
           !forceRestart {
            return nil
        }

        do {
            try powerAssertions.start(keepDisplayAwake: shouldKeepDisplayAwakeNow)
            return nil
        } catch {
            powerAssertions.stop()
            return error
        }
    }

    @objc private func toggleAutomaticAgentAwake() {
        let defaults = UserDefaults.standard
        let previousValue = automaticAgentAwakeEnabled
        defaults.set(!previousValue, forKey: automaticAgentAwakeKey)

        if let error = reconcilePowerAssertion() {
            defaults.set(previousValue, forKey: automaticAgentAwakeKey)
            _ = reconcilePowerAssertion()
            presentAssertionError(error)
        }

        updatePresentation()
        updateSettingsPresentation()
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
        let previousValue = shouldKeepDisplayAwake
        let newValue = !shouldKeepDisplayAwake

        defaults.set(newValue, forKey: keepDisplayAwakeKey)
        if shouldKeepAwake, let error = reconcilePowerAssertion(forceRestart: true) {
            defaults.set(previousValue, forKey: keepDisplayAwakeKey)
            _ = reconcilePowerAssertion(forceRestart: true)
            presentAssertionError(error)
        }

        updatePresentation()
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
