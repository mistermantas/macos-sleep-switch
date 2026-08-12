import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let stateItem = NSMenuItem(title: "Sleep follows macOS settings", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Keep Awake", action: #selector(toggleKeepAwake), keyEquivalent: "")
    private let durationMenu = NSMenu(title: "Manual Duration")
    private let awakeModeMenu = NSMenu(title: "Awake Mode")
    private let awakeModeItem = NSMenuItem(title: "Awake Mode", action: nil, keyEquivalent: "")
#if !APP_STORE
    private let coolingMenu = NSMenu(title: "Cooling")
    private let coolingItem = NSMenuItem(
        title: "Cooling · System Control",
        action: nil,
        keyEquivalent: ""
    )
    private let coolingStatusItem = NSMenuItem(
        title: "System Control",
        action: nil,
        keyEquivalent: ""
    )
    private let coolingHelperItem = NSMenuItem(
        title: "Install Cooling Helper…",
        action: #selector(manageCoolingHelper),
        keyEquivalent: ""
    )
    private let coolingDetailsItem = NSMenuItem(
        title: "Cooling Details…",
        action: #selector(showCoolingDetails),
        keyEquivalent: ""
    )
#endif
    private let automaticAgentAwakeItem = NSMenuItem(
        title: "Keep Awake for Agents",
        action: #selector(toggleAutomaticAgentAwake),
        keyEquivalent: ""
    )
    private let agentsHeaderItem = NSMenuItem(title: "Checking agents…", action: nil, keyEquivalent: "")
    private let agentsSeparator = NSMenuItem.separator()
    private let sleepDisplayItem = NSMenuItem(
        title: "Sleep Display",
        action: #selector(sleepDisplayNow),
        keyEquivalent: ""
    )
    private let sleepUntilAgentsFinishItem = NSMenuItem(
        title: "Sleep Until Agents Finish",
        action: nil,
        keyEquivalent: ""
    )
    private let insightsItem = NSMenuItem(
        title: "Insights…",
        action: #selector(showInsights),
        keyEquivalent: ""
    )
    private let settingsMenu = NSMenu(title: "Settings")
    private let supportMenu = NSMenu(title: AppLinks.menuTitle)
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
    private let saveHistoryItem = NSMenuItem(
        title: "Save Energy & Agent History",
        action: #selector(toggleHistorySaving),
        keyEquivalent: ""
    )
    private let deleteHistoryItem = NSMenuItem(
        title: "Delete History…",
        action: #selector(deleteHistory),
        keyEquivalent: ""
    )
    private let codexFolderItem = NSMenuItem(
        title: "Connect Codex…",
        action: #selector(connectCodex),
        keyEquivalent: ""
    )
    private let codexDirectoryAccess = CodexDirectoryAccess()
    private lazy var agentTracker: AgentTracker = {
#if APP_STORE
        let access = codexDirectoryAccess
        return AgentTracker(codexSessionsDirectory: { access.sessionsDirectory })
#else
        return AgentTracker()
#endif
    }()
    private let powerAssertions = PowerAssertionController()
    private let lidClosedSleep = LidClosedSleepController()
    private let displayPower = DisplayPowerController()
    private let insightsRecorder = InsightsRecorder()
    private var insightsWindowController: InsightsWindowController?
    private lazy var companionBridge = CompanionMacBridge(
        statusProvider: { [weak self] in
            self?.companionStatus() ?? CompanionMacStatus.unavailable
        },
        historyProvider: { [weak self] in
            self?.companionHistory() ?? .empty(deviceID: "unavailable")
        },
        commandHandler: { [weak self] command in
            self?.handleRemoteCommand(command)
                ?? CompanionRemoteResult(
                    commandID: command.id,
                    accepted: false,
                    executed: false,
                    completedAt: Date(),
                    message: "Sleep Switch is no longer running."
                )
        }
    )
#if !APP_STORE
    private let fanHelperClient = FanHelperClient()
    private lazy var coolingCoordinator = CoolingCoordinator(
        client: fanHelperClient
    )
    private var coolingProfileItems: [NSMenuItem] = []
    private var coolingDetailsWindow: CoolingDetailsWindowController?
    private let coolingWarningShownKey = "coolingWarningShown"
    private var coolingThermalAbortSuppressesAwake = false
#endif
    private let agentScanQueue = DispatchQueue(
        label: "lt.mantas.sleepswitch.agent-scan",
        qos: .utility
    )
    private let launchAtLoginConfiguredKey = "launchAtLoginConfigured"
    private let keepDisplayAwakeKey = "keepDisplayAwake"
    private let activateOnLaunchKey = "activateOnLaunch"
    private let defaultDurationSecondsKey = "defaultDurationSeconds"
    private let automaticAgentAwakeKey = "automaticAgentAwake"
    private let awakeModeKey = "awakeMode"
    private var manualAwakeSession: AwakeSession?
    private var detectedAgents: [DetectedAgent] = []
    private var agentItems: [NSMenuItem] = []
    private var awakeModeItems: [NSMenuItem] = []
    private var wakeDisplayWhenAgentsFinish = false
    private var displaySleepOverride = false
    private var agentScanInFlight = false
    private var refreshTimer: Timer?
    private var expiryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerDefaults()
#if APP_STORE
        codexDirectoryAccess.restoreAccess()
#endif
        configureMenu()
        insightsRecorder.start()
        observeDisplayWake()
#if !APP_STORE
        lidClosedSleep.onRestorationFailure = { [weak self] error in
            self?.presentAssertionError(error)
        }
        lidClosedSleep.onRestorationFinished = { [weak self] in
            self?.updatePresentation()
        }
#endif
#if !APP_STORE
        enableLaunchAtLoginByDefault()
        configureCoolingCoordinator()
        coolingCoordinator.start()
#endif

        if UserDefaults.standard.bool(forKey: activateOnLaunchKey) {
            startKeepingAwake(durationSeconds: defaultDurationSeconds)
        }

        refreshState()
        startRefreshTimer()
        companionBridge.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do {
            try lidClosedSleep.stop()
#if !APP_STORE
            coolingCoordinator.stop()
#endif
            return .terminateNow
        } catch {
            presentAssertionError(error)
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        expiryTimer?.invalidate()
        refreshTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        powerAssertions.stop()
        insightsRecorder.stop()
        companionBridge.stop()
        try? lidClosedSleep.stop()
#if !APP_STORE
        coolingCoordinator.stop()
#endif
    }

    private func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            keepDisplayAwakeKey: true,
            activateOnLaunchKey: false,
            defaultDurationSecondsKey: 0,
            automaticAgentAwakeKey: true,
            awakeModeKey: KeepAwakeMode.preventSleep.rawValue
        ])
    }

    private func observeDisplayWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(displayDidWake(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
    }

    @objc private func displayDidWake(_ notification: Notification) {
        guard displaySleepOverride else { return }
        displaySleepOverride = false
        reconcileAndUpdatePresentation()
    }

    private func configureMenu() {
        menu.delegate = self
#if APP_STORE
        automaticAgentAwakeItem.title = "Keep Awake for Codex"
        agentsHeaderItem.target = self
        agentsHeaderItem.action = #selector(connectCodex)
        agentsHeaderItem.isEnabled = true
        sleepUntilAgentsFinishItem.title = "Wake Display When Codex Finishes"
        sleepUntilAgentsFinishItem.action = #selector(toggleWakeWhenAgentsFinish)
#else
        agentsHeaderItem.isEnabled = false
        sleepUntilAgentsFinishItem.action = #selector(sleepUntilAgentsFinish)
#endif
        stateItem.isEnabled = false
        toggleItem.target = self
        automaticAgentAwakeItem.target = self
        sleepDisplayItem.target = self
        sleepUntilAgentsFinishItem.target = self
        insightsItem.target = self
        insightsItem.image = NSImage(
            systemSymbolName: "chart.xyaxis.line",
            accessibilityDescription: "Energy and agent insights"
        )

        automaticAgentAwakeItem.image = NSImage(
            systemSymbolName: "terminal.fill",
            accessibilityDescription: "Agent awake controls"
        )
        sleepDisplayItem.image = NSImage(
            systemSymbolName: "display",
            accessibilityDescription: "Sleep the display"
        )
        sleepUntilAgentsFinishItem.image = NSImage(
            systemSymbolName: "moon.zzz",
            accessibilityDescription: "Sleep until agents finish"
        )
        toggleItem.image = NSImage(
            systemSymbolName: "cup.and.saucer.fill",
            accessibilityDescription: "Manual awake controls"
        )

        let durationItem = NSMenuItem(title: "Manual Duration", action: nil, keyEquivalent: "")
        durationItem.submenu = durationMenu
        durationItem.image = NSImage(
            systemSymbolName: "timer",
            accessibilityDescription: "Manual awake duration"
        )
        configureDurationMenu()

        awakeModeItem.submenu = awakeModeMenu
        awakeModeItem.image = NSImage(
            systemSymbolName: "laptopcomputer",
            accessibilityDescription: "Choose how Sleep Switch prevents sleep"
        )
        configureAwakeModeMenu()

#if !APP_STORE
        coolingItem.submenu = coolingMenu
        coolingItem.image = NSImage(
            systemSymbolName: "fan",
            accessibilityDescription: "Cooling controls"
        )
        configureCoolingMenu()
#endif

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu
        settingsItem.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: "Sleep Switch settings"
        )
        configureSettingsMenu()

#if APP_STORE
        let refreshTitle = "Refresh Codex"
#else
        let refreshTitle = "Refresh Agents"
#endif
        let refreshItem = NSMenuItem(
            title: refreshTitle,
            action: #selector(refreshState),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        refreshItem.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Refresh agent status"
        )

        let supportItem = NSMenuItem(
            title: AppLinks.menuTitle,
            action: nil,
            keyEquivalent: ""
        )
        supportItem.submenu = supportMenu
        supportItem.image = NSImage(
            systemSymbolName: AppLinks.menuSymbolName,
            accessibilityDescription: "Support and creator links"
        )
        configureSupportMenu()

        let quitItem = NSMenuItem(
            title: "Quit Sleep Switch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        menu.addItem(stateItem)
        menu.addItem(awakeModeItem)
#if !APP_STORE
        menu.addItem(coolingItem)
#endif
        menu.addItem(.separator())
        menu.addItem(automaticAgentAwakeItem)
        menu.addItem(agentsHeaderItem)
        menu.addItem(agentsSeparator)
        menu.addItem(insightsItem)
#if APP_STORE
        menu.addItem(sleepUntilAgentsFinishItem)
#else
        menu.addItem(sleepDisplayItem)
        menu.addItem(sleepUntilAgentsFinishItem)
#endif
        menu.addItem(.separator())
        menu.addItem(toggleItem)
        menu.addItem(durationItem)
        menu.addItem(.separator())
        menu.addItem(settingsItem)
        menu.addItem(refreshItem)
        menu.addItem(supportItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu
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

    private func configureAwakeModeMenu() {
        let modes: [KeepAwakeMode] = AppDistribution.supportsLidClosedAwake
            ? KeepAwakeMode.allCases
            : [.preventSleep]

        for mode in modes {
            let item = NSMenuItem(
                title: mode.menuTitle,
                action: #selector(selectAwakeMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.toolTip = mode.toolTip
            item.image = NSImage(
                systemSymbolName: mode == .preventSleep
                    ? "cup.and.saucer"
                    : "laptopcomputer",
                accessibilityDescription: mode.menuTitle
            )
            awakeModeItems.append(item)
            awakeModeMenu.addItem(item)
        }
    }

#if !APP_STORE
    private func configureCoolingMenu() {
        coolingStatusItem.isEnabled = false
        coolingStatusItem.image = NSImage(
            systemSymbolName: "fan",
            accessibilityDescription: "Verified cooling state"
        )
        coolingMenu.addItem(coolingStatusItem)
        coolingMenu.addItem(.separator())

        for profile in CoolingProfile.allCases {
            let item = NSMenuItem(
                title: profile.menuTitle,
                action: #selector(selectCoolingProfile(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile.rawValue
            item.image = NSImage(
                systemSymbolName: coolingSymbol(for: profile),
                accessibilityDescription: profile.menuTitle
            )
            coolingProfileItems.append(item)
            coolingMenu.addItem(item)
        }

        coolingMenu.addItem(.separator())
        coolingHelperItem.target = self
        coolingHelperItem.image = NSImage(
            systemSymbolName: "wrench.and.screwdriver",
            accessibilityDescription: "Cooling helper settings"
        )
        coolingMenu.addItem(coolingHelperItem)

        coolingDetailsItem.target = self
        coolingDetailsItem.image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.50percent",
            accessibilityDescription: "Cooling details"
        )
        coolingMenu.addItem(coolingDetailsItem)
    }
#endif

    private func configureSettingsMenu() {
        keepDisplayAwakeItem.target = self
        activateOnLaunchItem.target = self
        launchAtLoginItem.target = self
        codexFolderItem.target = self
        saveHistoryItem.target = self
        deleteHistoryItem.target = self
        saveHistoryItem.image = NSImage(
            systemSymbolName: "internaldrive",
            accessibilityDescription: "Save local history"
        )
        deleteHistoryItem.image = NSImage(
            systemSymbolName: "trash",
            accessibilityDescription: "Delete local history"
        )

        let defaultDurationItem = NSMenuItem(
            title: "Default Duration",
            action: nil,
            keyEquivalent: ""
        )
        defaultDurationItem.submenu = defaultDurationMenu
        configureDefaultDurationMenu()

#if APP_STORE
        settingsMenu.addItem(codexFolderItem)
        settingsMenu.addItem(.separator())
#endif
        settingsMenu.addItem(keepDisplayAwakeItem)
        settingsMenu.addItem(activateOnLaunchItem)
        settingsMenu.addItem(defaultDurationItem)
        settingsMenu.addItem(saveHistoryItem)
        settingsMenu.addItem(deleteHistoryItem)
        settingsMenu.addItem(.separator())
        settingsMenu.addItem(launchAtLoginItem)
    }

    private func configureSupportMenu() {
        for (groupIndex, group) in AppLinks.groups.enumerated() {
            if groupIndex > 0 {
                supportMenu.addItem(.separator())
            }

            for link in group {
                let item = NSMenuItem(
                    title: link.title,
                    action: #selector(openAppLink(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = link
                item.image = NSImage(
                    systemSymbolName: link.symbolName,
                    accessibilityDescription: link.title
                )
                supportMenu.addItem(item)
            }
        }

        supportMenu.addItem(.separator())
        let versionItem = NSMenuItem(
            title: AppLinks.currentVersionTitle,
            action: nil,
            keyEquivalent: ""
        )
        versionItem.isEnabled = false
        versionItem.image = NSImage(
            systemSymbolName: "info.circle",
            accessibilityDescription: AppLinks.currentVersionTitle
        )
        supportMenu.addItem(versionItem)
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

    func menuWillOpen(_ menu: NSMenu) {
        if displaySleepOverride {
            displaySleepOverride = false
            _ = reconcilePowerAssertion()
        }
        refreshState()
    }

    @objc private func refreshState() {
        if manualAwakeSession?.hasExpired() == true {
            clearManualAwakeSession()
        }

        reconcileAndUpdatePresentation()
        requestAgentScan()
    }

    private func requestAgentScan() {
        guard !agentScanInFlight else { return }
        agentScanInFlight = true
        let tracker = agentTracker

        agentScanQueue.async { [weak self] in
            let latestAgents = tracker.scan()
            DispatchQueue.main.async { [weak self] in
                self?.completeAgentScan(latestAgents)
            }
        }
    }

    private func completeAgentScan(_ latestAgents: [DetectedAgent]?) {
        agentScanInFlight = false
        guard let latestAgents else { return }

        detectedAgents = latestAgents
        insightsRecorder.recordAgents(latestAgents)
#if !APP_STORE
        if detectedAgents.isEmpty,
           ProcessInfoThermalMonitor().currentLevel != .critical {
            coolingThermalAbortSuppressesAwake = false
        }
#endif
        attemptQueuedDisplayWakeIfNeeded()
        reconcileAndUpdatePresentation()
        companionBridge.synchronize()
    }

    private func companionStatus() -> CompanionMacStatus {
        let reading = IOKitPowerTelemetryProvider().read()
        let sessionCount = detectedAgents.reduce(0) { $0 + $1.processCount }
        let thermalState: String = switch ProcessInfo.processInfo.thermalState {
        case .nominal:
            "nominal"
        case .fair:
            "fair"
        case .serious:
            "serious"
        case .critical:
            "critical"
        @unknown default:
            "unknown"
        }

        return CompanionMacStatus(
            deviceID: companionBridge.deviceID,
            displayName: Host.current().localizedName ?? "This Mac",
            build: AppLinks.currentVersionTitle,
            lastSeen: Date(),
            uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            powerSource: reading.source,
            batteryPercent: reading.batteryPercent,
            thermalState: thermalState,
            activeAgentCount: detectedAgents.count,
            activeSessionCount: sessionCount,
            awakeMode: selectedAwakeMode.rawValue,
            displayAsleep: displaySleepOverride,
            isKeepingAwake: powerAssertions.isActive || lidClosedSleep.isActive,
            keepDisplayAwake: shouldKeepDisplayAwake,
            automaticAgentAwakeEnabled: automaticAgentAwakeEnabled,
            wakeDisplayWhenAgentsFinish: wakeDisplayWhenAgentsFinish,
            estimatedWatts: reading.watts,
            energySource: reading.source,
            energyConfidence: reading.confidence,
            isCharging: reading.isCharging,
            capabilities: RemoteEnergyController.capabilities
        )
    }

    private func companionHistory() -> CompanionHistorySnapshot {
        CompanionHistoryBuilder.make(
            deviceID: companionBridge.deviceID,
            snapshot: insightsRecorder.snapshot(for: .month)
        )
    }

    private func handleRemoteCommand(
        _ command: CompanionRemoteCommand
    ) -> CompanionRemoteResult {
        let now = Date()
        let capabilities = RemoteEnergyController.capabilities
        let validation = CompanionCommandPolicy.validate(
            command,
            targetDeviceID: companionBridge.deviceID,
            capabilities: capabilities,
            now: now
        )

        guard case .success = validation else {
            let message: String? = switch validation {
            case .success:
                nil
            case .failure(let error):
                "Remote action rejected: \(String(describing: error))."
            }
            return CompanionRemoteResult(
                commandID: command.id,
                accepted: false,
                executed: false,
                completedAt: now,
                message: message
            )
        }

        do {
            switch command.action {
            case .sleepMac:
                try RemoteEnergyController.sleepMac()
            case .sleepDisplay:
                try sleepDisplayForRemote()
            case .wakeDisplay:
                try RemoteEnergyController.wakeDisplay(using: displayPower)
                displaySleepOverride = false
                reconcileAndUpdatePresentation()
            case .wakeMac:
                throw RemoteEnergyError.unavailable(
                    "A fully sleeping Mac cannot poll CloudKit. Enable Wake on Network Access in macOS for a future wake service."
                )
            case .lockMac:
#if !APP_STORE
                try RemoteEnergyController.lockMac()
#else
                throw RemoteEnergyError.unavailable("Locking is not available in the Mac App Store build.")
#endif
            case .restartMac:
#if !APP_STORE
                try RemoteEnergyController.restartMac()
#else
                throw RemoteEnergyError.unavailable("Restart is not available in the Mac App Store build.")
#endif
            case .shutdownMac:
#if !APP_STORE
                try RemoteEnergyController.shutdownMac()
#else
                throw RemoteEnergyError.unavailable("Shutdown is not available in the Mac App Store build.")
#endif
            case .sleepDisplayUntilAgentsFinish:
#if !APP_STORE
                try sleepDisplayForRemote(wakeWhenAgentsFinish: true)
#else
                throw RemoteEnergyError.unavailable("Display sleep is not available in the Mac App Store build.")
#endif
            case .setKeepAwake:
                applyRemoteKeepAwake(command.parameters)
            case .panicStop:
                clearManualAwakeSession()
                wakeDisplayWhenAgentsFinish = false
                displaySleepOverride = false
                UserDefaults.standard.set(false, forKey: automaticAgentAwakeKey)
                _ = reconcilePowerAssertion(forceRestart: true)
                reconcileAndUpdatePresentation()
            }

            return CompanionRemoteResult(
                commandID: command.id,
                accepted: true,
                executed: true,
                completedAt: Date(),
                message: "\(command.action.title) completed."
            )
        } catch {
            return CompanionRemoteResult(
                commandID: command.id,
                accepted: true,
                executed: false,
                completedAt: Date(),
                message: error.localizedDescription
            )
        }
    }

    private func applyRemoteKeepAwake(_ parameters: [String: String]) {
        let defaults = UserDefaults.standard
        if let enabled = parameters["enabled"].flatMap(Bool.init) {
            defaults.set(enabled, forKey: automaticAgentAwakeKey)
        }
        if let keepDisplayAwake = parameters["keepDisplayAwake"].flatMap(Bool.init) {
            defaults.set(keepDisplayAwake, forKey: keepDisplayAwakeKey)
        }
        if let wakeWhenAgentsFinish = parameters["wakeWhenAgentsFinish"].flatMap(Bool.init) {
            self.wakeDisplayWhenAgentsFinish = wakeWhenAgentsFinish
        }
        reconcileAndUpdatePresentation()
    }

    private func sleepDisplayForRemote(wakeWhenAgentsFinish: Bool = false) throws {
#if APP_STORE
        _ = wakeWhenAgentsFinish
        throw RemoteEnergyError.unavailable("Display sleep is not available in the Mac App Store build.")
#else
        let previousWakeState = wakeDisplayWhenAgentsFinish
        let previousDisplaySleepOverride = displaySleepOverride
        self.wakeDisplayWhenAgentsFinish = wakeWhenAgentsFinish
        self.displaySleepOverride = true

        if let error = reconcilePowerAssertion(forceRestart: true) {
            self.wakeDisplayWhenAgentsFinish = previousWakeState
            self.displaySleepOverride = previousDisplaySleepOverride
            _ = reconcilePowerAssertion(forceRestart: true)
            throw error
        }

        do {
            try RemoteEnergyController.sleepDisplay(using: displayPower)
        } catch {
            self.wakeDisplayWhenAgentsFinish = previousWakeState
            self.displaySleepOverride = previousDisplaySleepOverride
            _ = reconcilePowerAssertion(forceRestart: true)
            throw error
        }
        updatePresentation()
        updateDisplayPresentation()
#endif
    }

    private func reconcileAndUpdatePresentation() {
        let attemptedMode = selectedAwakeMode
        if let error = reconcilePowerAssertion(),
           attemptedMode == .lidClosed {
            UserDefaults.standard.set(
                KeepAwakeMode.preventSleep.rawValue,
                forKey: awakeModeKey
            )
            _ = reconcilePowerAssertion(forceRestart: true)
            presentAssertionError(error)
        }
        updatePresentation()
        updateAgentPresentation()
        updateDisplayPresentation()
        updateSettingsPresentation()
#if !APP_STORE
        synchronizeCoolingOwnership()
        updateCoolingPresentation()
#endif
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

    private var selectedAwakeMode: KeepAwakeMode {
        guard AppDistribution.supportsLidClosedAwake else {
            return .preventSleep
        }
        let storedValue = UserDefaults.standard.string(forKey: awakeModeKey)
        return KeepAwakeMode.persistedMode(from: storedValue)
    }

    private var shouldKeepDisplayAwakeNow: Bool {
        manualAwakeSession != nil && shouldKeepDisplayAwake && !displaySleepOverride
    }

    private var agentAwakeRequested: Bool {
        (automaticAgentAwakeEnabled || wakeDisplayWhenAgentsFinish)
            && !detectedAgents.isEmpty
    }

    private var shouldKeepAwake: Bool {
#if !APP_STORE
        guard !coolingThermalAbortSuppressesAwake else {
            return false
        }
#endif
        return AwakePolicy.shouldKeepAwake(
            manualSession: manualAwakeSession,
            automaticAgentAwakeEnabled: automaticAgentAwakeEnabled,
            wakeWhenAgentsFinishArmed: wakeDisplayWhenAgentsFinish,
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
        stateItem.image = NSImage(
            systemSymbolName: presentation.symbolName,
            accessibilityDescription: presentation.accessibilityDescription
        )
        toggleItem.title = manualAwakeSession == nil
            ? "Start Manual Session"
            : "Stop Manual Session"
        toggleItem.toolTip = "Uses \(selectedAwakeMode.menuTitle)"
        toggleItem.image = NSImage(
            systemSymbolName: manualAwakeSession == nil
                ? "cup.and.saucer.fill"
                : "stop.circle",
            accessibilityDescription: toggleItem.title
        )
        awakeModeItem.title = "Awake Mode · \(selectedAwakeMode.shortTitle)"
        awakeModeItem.toolTip = selectedAwakeMode.toolTip
        updateAwakeModeChecks()
        updateDurationChecks()
    }

    private var awakePresentation: (
        symbolName: String,
        accessibilityDescription: String,
        toolTip: String,
        stateTitle: String
    ) {
        if lidClosedSleep.isRestoring {
            return (
                "arrow.clockwise",
                "Sleep Switch is restoring normal lid sleep",
                "Restoring normal lid sleep…",
                "Restoring normal lid sleep…"
            )
        }

        if wakeDisplayWhenAgentsFinish {
            if detectedAgents.isEmpty {
                return (
                    "exclamationmark.triangle",
                    "Sleep Switch is still trying to wake the display",
                    "Display wake pending · Click for controls",
                    "Display wake pending · \(selectedAwakeMode.stateTitle)"
                )
            }

            let agentName = detectedAgents.count == 1
                ? detectedAgents[0].definition.name
                : "\(detectedAgents.count) agents"
            return (
                "moon.zzz.fill",
                "Sleep Switch will wake the display when \(agentName) finishes",
                "Wake queued for \(agentName) · Click for controls",
                "Wake queued · \(agentName) · \(selectedAwakeMode.stateTitle)"
            )
        }

        if let manualAwakeSession {
            guard let remainingSeconds = manualAwakeSession.remainingSeconds() else {
                return (
                    "cup.and.saucer.fill",
                    "Sleep Switch keeping this Mac awake manually in \(selectedAwakeMode.menuTitle) mode",
                    "Awake manually · \(selectedAwakeMode.stateTitle) · Click for controls",
                    "Awake · Manual · \(selectedAwakeMode.stateTitle)"
                )
            }

            let remainingText = AwakeTimeText.remaining(seconds: remainingSeconds)
            return (
                "timer",
                "Sleep Switch keeping this Mac awake for \(remainingText) in \(selectedAwakeMode.menuTitle) mode",
                "\(remainingText) · \(selectedAwakeMode.stateTitle) · Click for controls",
                "Awake · \(remainingText) · \(selectedAwakeMode.stateTitle)"
            )
        }

        if agentAwakeRequested && powerAssertions.isActive {
            let agentName = detectedAgents.count == 1
                ? detectedAgents[0].definition.name
                : "\(detectedAgents.count) agents"
            return (
                "terminal.fill",
                "Sleep Switch keeping this Mac awake for \(agentName) in \(selectedAwakeMode.menuTitle) mode",
                "Awake for \(agentName) · \(selectedAwakeMode.stateTitle) · Click for controls",
                "Awake · \(agentName) · \(selectedAwakeMode.stateTitle)"
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
            "Sleep follows macOS settings · Click for controls",
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

    private func updateAwakeModeChecks() {
        for item in awakeModeItems {
            guard let rawValue = item.representedObject as? String else { continue }
            item.state = rawValue == selectedAwakeMode.rawValue ? .on : .off
        }
    }

    private func updateAgentPresentation() {
        agentItems.forEach(menu.removeItem)
        agentItems.removeAll()

#if APP_STORE
        if !codexDirectoryAccess.isConnected {
            agentsHeaderItem.title = "Connect Codex…"
            agentsHeaderItem.image = NSImage(
                systemSymbolName: "folder.badge.plus",
                accessibilityDescription: "Connect the Codex folder"
            )
            agentsHeaderItem.isEnabled = true
            return
        }
        agentsHeaderItem.isEnabled = false
#endif

        let sessionCount = detectedAgents.reduce(0) { $0 + $1.processCount }
        if sessionCount == 0 {
#if APP_STORE
            agentsHeaderItem.title = "No Codex tasks running"
#else
            agentsHeaderItem.title = "No supported agents running"
#endif
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

    private func updateDisplayPresentation() {
#if APP_STORE
        if wakeDisplayWhenAgentsFinish {
            sleepUntilAgentsFinishItem.title = "Cancel Wake When Codex Finishes"
            sleepUntilAgentsFinishItem.state = .on
            sleepUntilAgentsFinishItem.isEnabled = true
            sleepUntilAgentsFinishItem.image = NSImage(
                systemSymbolName: "moon.zzz.fill",
                accessibilityDescription: "Display wake queued"
            )
            sleepUntilAgentsFinishItem.toolTip = "The display will wake after every Codex task ends"
            return
        }

        sleepUntilAgentsFinishItem.title = "Wake Display When Codex Finishes"
        sleepUntilAgentsFinishItem.state = .off
        sleepUntilAgentsFinishItem.isEnabled = !detectedAgents.isEmpty
        sleepUntilAgentsFinishItem.image = NSImage(
            systemSymbolName: "sunrise",
            accessibilityDescription: "Wake the display when Codex finishes"
        )
        sleepUntilAgentsFinishItem.toolTip = detectedAgents.isEmpty
            ? "Available while a Codex task is running"
            : "Wake the display after every Codex task ends"
#else
        sleepDisplayItem.state = .off
        sleepDisplayItem.toolTip = "Turn off the display without sleeping or logging out of the Mac"

        if wakeDisplayWhenAgentsFinish {
            sleepUntilAgentsFinishItem.title = "Cancel Wake When Agents Finish"
            sleepUntilAgentsFinishItem.state = .on
            sleepUntilAgentsFinishItem.isEnabled = true
            sleepUntilAgentsFinishItem.image = NSImage(
                systemSymbolName: "moon.zzz.fill",
                accessibilityDescription: "Wake queued"
            )
            sleepUntilAgentsFinishItem.toolTip = "The display will wake after every detected agent session ends"
            return
        }

        sleepUntilAgentsFinishItem.title = "Sleep Until Agents Finish"
        sleepUntilAgentsFinishItem.state = .off
        sleepUntilAgentsFinishItem.isEnabled = !detectedAgents.isEmpty
        sleepUntilAgentsFinishItem.image = NSImage(
            systemSymbolName: "moon.zzz",
            accessibilityDescription: "Sleep until agents finish"
        )
        sleepUntilAgentsFinishItem.toolTip = detectedAgents.isEmpty
            ? "Available while a supported agent is running"
            : "Turn off the display, then wake it after every detected agent session ends"
#endif
    }

    private func updateSettingsPresentation() {
        let defaults = UserDefaults.standard
        automaticAgentAwakeItem.state = automaticAgentAwakeEnabled ? .on : .off
        keepDisplayAwakeItem.state = shouldKeepDisplayAwake ? .on : .off
        activateOnLaunchItem.state = defaults.bool(forKey: activateOnLaunchKey) ? .on : .off
        saveHistoryItem.state = insightsRecorder.historyEnabled ? .on : .off
        deleteHistoryItem.isEnabled = insightsRecorder.storageBytes > 0

        let selectedDefault = defaults.integer(forKey: defaultDurationSecondsKey)
        for item in defaultDurationMenu.items {
            guard let seconds = item.representedObject as? Int else { continue }
            item.state = seconds == selectedDefault ? .on : .off
        }

#if APP_STORE
        codexFolderItem.title = codexDirectoryAccess.isConnected
            ? "Change Codex Folder…"
            : "Connect Codex…"
#endif
        updateLaunchAtLoginPresentation()
    }

    private func startRefreshTimer() {
        let timer = Timer.scheduledTimer(
            timeInterval: 10,
            target: self,
            selector: #selector(refreshState),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 2
        refreshTimer = timer
    }

    private func attemptQueuedDisplayWakeIfNeeded() {
        guard DisplayWakePolicy.shouldAttemptWake(
            isArmed: wakeDisplayWhenAgentsFinish,
            detectedAgents: detectedAgents
        ) else {
            return
        }

        do {
            try displayPower.wakeDisplay()
            wakeDisplayWhenAgentsFinish = false
            displaySleepOverride = false
        } catch {
            // Keep the one-shot mode armed so the next agent refresh can retry.
        }
    }

    @objc private func sleepDisplayNow() {
        sleepDisplay(wakeWhenAgentsFinish: false)
    }

    @objc private func showInsights() {
        if insightsWindowController == nil {
            insightsWindowController = InsightsWindowController(
                recorder: insightsRecorder
            )
        }
        insightsWindowController?.show()
    }

    @objc private func toggleHistorySaving() {
        insightsRecorder.setHistoryEnabled(!insightsRecorder.historyEnabled)
        updateSettingsPresentation()
    }

    @objc private func deleteHistory() {
        let alert = NSAlert()
        alert.messageText = "Delete local history?"
        alert.informativeText = "Energy buckets and agent activity intervals will be removed from this Mac."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try insightsRecorder.deleteHistory()
            updateSettingsPresentation()
        } catch {
            presentAssertionError(error)
        }
    }

#if APP_STORE
    @objc private func toggleWakeWhenAgentsFinish() {
        if wakeDisplayWhenAgentsFinish {
            wakeDisplayWhenAgentsFinish = false
            _ = reconcilePowerAssertion()
            reconcileAndUpdatePresentation()
            return
        }

        guard !detectedAgents.isEmpty else {
            NSSound.beep()
            return
        }

        wakeDisplayWhenAgentsFinish = true
        if let error = reconcilePowerAssertion() {
            wakeDisplayWhenAgentsFinish = false
            presentAssertionError(error)
        }
        reconcileAndUpdatePresentation()
    }
#else
    @objc private func sleepUntilAgentsFinish() {
        if wakeDisplayWhenAgentsFinish {
            wakeDisplayWhenAgentsFinish = false
            displaySleepOverride = false
            _ = reconcilePowerAssertion()
            updatePresentation()
            updateDisplayPresentation()
            return
        }

        guard !detectedAgents.isEmpty else {
            NSSound.beep()
            return
        }
        sleepDisplay(wakeWhenAgentsFinish: true)
    }
#endif

    private func sleepDisplay(wakeWhenAgentsFinish: Bool) {
        let previousWakeState = wakeDisplayWhenAgentsFinish
        let previousDisplaySleepOverride = displaySleepOverride

        wakeDisplayWhenAgentsFinish = wakeWhenAgentsFinish
        displaySleepOverride = true

        if let error = reconcilePowerAssertion(forceRestart: true) {
            wakeDisplayWhenAgentsFinish = previousWakeState
            displaySleepOverride = previousDisplaySleepOverride
            _ = reconcilePowerAssertion(forceRestart: true)
            presentAssertionError(error)
            updatePresentation()
            updateDisplayPresentation()
            return
        }

        do {
            try displayPower.sleepDisplay()
        } catch {
            wakeDisplayWhenAgentsFinish = previousWakeState
            displaySleepOverride = previousDisplaySleepOverride
            _ = reconcilePowerAssertion(forceRestart: true)
            presentAssertionError(error)
        }

        updatePresentation()
        updateDisplayPresentation()
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
#if !APP_STORE
        coolingThermalAbortSuppressesAwake = false
#endif
        expiryTimer?.invalidate()

        let session = AwakeSession(startedAt: Date(), durationSeconds: durationSeconds)
        manualAwakeSession = session

        if let error = reconcilePowerAssertion() {
            manualAwakeSession = nil
            presentAssertionError(error)
            updatePresentation()
#if !APP_STORE
            synchronizeCoolingOwnership()
#endif
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
#if !APP_STORE
        synchronizeCoolingOwnership()
#endif
    }

    private func stopKeepingAwake() {
        clearManualAwakeSession()
        if let error = reconcilePowerAssertion() {
            presentAssertionError(error)
        }
        updatePresentation()
#if !APP_STORE
        synchronizeCoolingOwnership()
#endif
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
            do {
                try lidClosedSleep.stop(waitForRestoration: false)
                return nil
            } catch {
                return error
            }
        }

        do {
            switch selectedAwakeMode {
            case .preventSleep:
                try lidClosedSleep.stop(waitForRestoration: false)
            case .lidClosed:
                try lidClosedSleep.start()
            }
        } catch {
            return error
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
            if selectedAwakeMode == .lidClosed {
                try? lidClosedSleep.stop(waitForRestoration: false)
            }
            return error
        }
    }

    @objc private func selectAwakeMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = KeepAwakeMode(rawValue: rawValue),
              mode != selectedAwakeMode else {
            return
        }
        guard mode != .lidClosed || AppDistribution.supportsLidClosedAwake else {
            NSSound.beep()
            return
        }

        let defaults = UserDefaults.standard
        let previousMode = selectedAwakeMode
        defaults.set(mode.rawValue, forKey: awakeModeKey)

        if shouldKeepAwake,
           let error = reconcilePowerAssertion(forceRestart: true) {
            defaults.set(previousMode.rawValue, forKey: awakeModeKey)
            _ = reconcilePowerAssertion(forceRestart: true)
            presentAssertionError(error)
        }

        updatePresentation()
        updateSettingsPresentation()
    }

    @objc private func toggleAutomaticAgentAwake() {
        let defaults = UserDefaults.standard
        let previousValue = automaticAgentAwakeEnabled
        defaults.set(!previousValue, forKey: automaticAgentAwakeKey)
#if !APP_STORE
        if !previousValue {
            coolingThermalAbortSuppressesAwake = false
        }
#endif

        if let error = reconcilePowerAssertion() {
            defaults.set(previousValue, forKey: automaticAgentAwakeKey)
            _ = reconcilePowerAssertion()
            presentAssertionError(error)
        }

        updatePresentation()
        updateSettingsPresentation()
#if !APP_STORE
        synchronizeCoolingOwnership()
#endif
    }

#if !APP_STORE
    private func synchronizeCoolingOwnership() {
        coolingCoordinator.updateAwakeOwnership(
            shouldKeepAwake && powerAssertions.isActive
        )
    }

    private func configureCoolingCoordinator() {
        coolingCoordinator.onChange = { [weak self] presentation in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateCoolingPresentation()
                self.coolingDetailsWindow?.update(presentation)
            }
        }
        coolingCoordinator.onThermalAbort = { [weak self] reason in
            DispatchQueue.main.async {
                self?.handleCoolingThermalAbort(reason)
            }
        }
    }

    private func updateCoolingPresentation() {
        let presentation = coolingCoordinator.presentation
        let profile = presentation.selectedProfile
        let snapshot = presentation.helperSnapshot

        coolingItem.title = "Cooling · \(presentation.effectiveTitle)"
        coolingItem.image = NSImage(
            systemSymbolName: presentation.hasActiveLease
                ? "fan.fill"
                : "fan",
            accessibilityDescription: "Cooling controls"
        )
        coolingStatusItem.title = coolingStatusTitle(presentation)
        coolingStatusItem.image = NSImage(
            systemSymbolName: coolingStatusSymbol(presentation),
            accessibilityDescription: coolingStatusItem.title
        )

        for item in coolingProfileItems {
            guard let rawValue = item.representedObject as? String,
                  let itemProfile = CoolingProfile(rawValue: rawValue)
            else {
                continue
            }
            item.state = itemProfile == profile ? .on : .off

            if itemProfile == .systemControl {
                item.isEnabled = true
            } else if presentation.registrationState
                        == .requiresSignedBuild {
                item.isEnabled = false
            } else if presentation.registrationState != .enabled {
                item.isEnabled = true
            } else if let qualification = snapshot?.qualification {
                item.isEnabled = itemProfile == .maximum
                    ? qualification.permitsMaximumControl
                    : qualification.permitsAggressiveControl
            } else {
                item.isEnabled = true
            }
        }

        coolingHelperItem.title = switch presentation.registrationState {
        case .requiresSignedBuild:
            "Signed Build Required…"
        case .notRegistered:
            "Install Cooling Helper…"
        case .requiresApproval:
            "Approve Cooling Helper…"
        case .notFound:
            "Repair Cooling Helper…"
        case .enabled:
            "Cooling Helper Settings…"
        }
        coolingDetailsItem.isEnabled = snapshot != nil
            || ![
                FanHelperRegistrationState.notFound,
                .requiresSignedBuild
            ].contains(presentation.registrationState)
        coolingDetailsWindow?.update(presentation)
    }

    private func coolingStatusTitle(
        _ presentation: CoolingPresentationSnapshot
    ) -> String {
        guard let snapshot = presentation.helperSnapshot else {
            return switch presentation.registrationState {
            case .requiresSignedBuild:
                "Signed Build Required"
            case .notRegistered:
                "Helper Not Installed"
            case .requiresApproval:
                "Approval Needed"
            case .notFound:
                "Helper Unavailable"
            case .enabled:
                "Connecting…"
            }
        }

        let temperature = snapshot.optionalAggregateTemperatureCelsius.map {
            " · \(Int($0.rounded()))°"
        } ?? ""
        return switch snapshot.state {
        case .systemControl:
            "System Control\(temperature)"
        case .cooling:
            "\(presentation.selectedProfile.menuTitle)\(temperature)"
        case .monitoringOnly:
            "Monitoring Only\(temperature)"
        case .unsupported:
            "No Supported Fans"
        case .externalControllerConflict:
            "Macs Fan Control Is Open"
        case .unavailable:
            "Cooling Unavailable"
        case .restoreFailed:
            "Restoration Needs Attention"
        }
    }

    private func coolingStatusSymbol(
        _ presentation: CoolingPresentationSnapshot
    ) -> String {
        guard let state = presentation.helperSnapshot?.state else {
            return switch presentation.registrationState {
            case .requiresSignedBuild:
                "lock"
            case .requiresApproval:
                "exclamationmark.triangle"
            case .notRegistered, .enabled, .notFound:
                "fan"
            }
        }
        return switch state {
        case .cooling:
            "fan.fill"
        case .restoreFailed:
            "exclamationmark.triangle"
        case .externalControllerConflict:
            "exclamationmark.circle"
        case .systemControl, .monitoringOnly, .unsupported, .unavailable:
            "fan"
        }
    }

    private func coolingSymbol(for profile: CoolingProfile) -> String {
        switch profile {
        case .systemControl:
            return "apple.logo"
        case .aggressive:
            return "fan"
        case .maximum:
            return "fan.fill"
        }
    }

    @objc private func selectCoolingProfile(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let profile = CoolingProfile(rawValue: rawValue)
        else {
            return
        }

        if profile != .systemControl,
           fanHelperClient.registrationState == .requiresSignedBuild {
            presentAssertionError(
                FanHelperClientError.requiresSignedBuild
            )
            return
        }

        if profile != .systemControl,
           !UserDefaults.standard.bool(forKey: coolingWarningShownKey) {
            let alert = NSAlert()
            alert.messageText = "Cooling needs open airflow"
            alert.informativeText =
                "Use Sleep Switch on a hard, ventilated surface. "
                + "Never rely on fan control to make a closed bag or sleeve safe."
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
            UserDefaults.standard.set(true, forKey: coolingWarningShownKey)
        }

        coolingCoordinator.selectProfile(profile)
        guard profile != .systemControl else {
            coolingThermalAbortSuppressesAwake = false
            reconcileAndUpdatePresentation()
            return
        }

        switch fanHelperClient.registrationState {
        case .requiresSignedBuild:
            presentAssertionError(
                FanHelperClientError.requiresSignedBuild
            )
        case .notRegistered, .notFound:
            installCoolingHelper()
        case .requiresApproval:
            fanHelperClient.openLoginItemsSettings()
        case .enabled:
            coolingCoordinator.refreshStatus()
        }
        updateCoolingPresentation()
    }

    @objc private func manageCoolingHelper() {
        switch fanHelperClient.registrationState {
        case .requiresSignedBuild:
            presentAssertionError(
                FanHelperClientError.requiresSignedBuild
            )
        case .notRegistered, .notFound:
            installCoolingHelper()
        case .requiresApproval:
            fanHelperClient.openLoginItemsSettings()
        case .enabled:
            let alert = NSAlert()
            alert.messageText = "Cooling Helper"
            alert.informativeText =
                "The helper is enabled and restores macOS control whenever "
                + "its cooling lease ends."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Remove Helper")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                fanHelperClient.openLoginItemsSettings()
            case .alertSecondButtonReturn:
                fanHelperClient.unregister { [weak self] error in
                    DispatchQueue.main.async {
                        if let error {
                            self?.presentAssertionError(error)
                        }
                        self?.coolingCoordinator.refreshStatus()
                    }
                }
            default:
                break
            }
        }
    }

    private func installCoolingHelper() {
        do {
            try fanHelperClient.register()
            if fanHelperClient.registrationState == .requiresApproval {
                fanHelperClient.openLoginItemsSettings()
            }
            coolingCoordinator.refreshStatus()
        } catch {
            presentAssertionError(error)
        }
    }

    @objc private func showCoolingDetails() {
        let controller = coolingDetailsWindow
            ?? CoolingDetailsWindowController()
        coolingDetailsWindow = controller
        controller.show(coolingCoordinator.presentation)
    }

    private func handleCoolingThermalAbort(
        _ reason: CoolingAbortReason
    ) {
        guard !coolingThermalAbortSuppressesAwake else { return }
        coolingThermalAbortSuppressesAwake = true
        clearManualAwakeSession()
        wakeDisplayWhenAgentsFinish = false
        displaySleepOverride = false
        powerAssertions.stop()
        try? lidClosedSleep.stop(waitForRestoration: false)
        coolingCoordinator.updateAwakeOwnership(false)
        reconcileAndUpdatePresentation()

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Cooling stopped the awake session"
        alert.informativeText = switch reason {
        case .criticalSystemThermalState:
            "macOS reported critical thermal pressure. Sleep Switch restored system fan control and released its awake request."
        case .invalidTemperature, .missingTemperature, .staleTemperature:
            "Reliable temperature feedback was lost. Sleep Switch restored system fan control and released its awake request."
        case .sustainedHighTemperature:
            "The Mac stayed above 80° while maximum cooling was verified. Sleep Switch restored system fan control and released its awake request."
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
#endif

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
        if let lidError = error as? LidClosedSleepError,
           case .authorizationCancelled = lidError {
            return
        }
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

    @objc private func openAppLink(_ sender: NSMenuItem) {
        guard let link = sender.representedObject as? AppLink else { return }
        NSWorkspace.shared.open(link.url)
    }

    @objc private func connectCodex() {
#if APP_STORE
        guard codexDirectoryAccess.requestAccess() else { return }
        detectedAgents = []
        updateAgentPresentation()
        updateSettingsPresentation()
        requestAgentScan()
#endif
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
#if !APP_STORE
        if CommandLine.arguments.contains(
            CoolingHelperMaintenance.refreshArgument
        ) {
            let app = NSApplication.shared
            let delegate = CoolingHelperMaintenance()
            app.delegate = delegate
            app.setActivationPolicy(.prohibited)
            app.run()
            exit(Int32(delegate.exitCode))
        }
#endif

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
