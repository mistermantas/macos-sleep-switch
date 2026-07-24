import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let stateItem = NSMenuItem(title: "Checking sleep setting…", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Toggle", action: #selector(toggleSleepPrevention), keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let launchAtLoginConfiguredKey = "launchAtLoginConfigured"
    private var sleepPreventionEnabled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        enableLaunchAtLoginByDefault()
        refreshState()
    }

    private func configureMenu() {
        menu.delegate = self
        stateItem.isEnabled = false
        toggleItem.target = self
        launchAtLoginItem.target = self

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshState), keyEquivalent: "r")
        refreshItem.target = self

        let quitItem = NSMenuItem(title: "Quit Sleep Switch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(toggleItem)
        menu.addItem(.separator())
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
        updatePresentation()
        updateLaunchAtLoginPresentation()
    }

    private func readSleepPreventionState() -> Bool {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "custom"]
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
                    guard parts.count == 2, parts[0] == "disablesleep" else { return nil }
                    return Int(parts[1])
                }

            return !values.isEmpty && values.allSatisfy { $0 == 1 }
        } catch {
            return false
        }
    }

    private func updatePresentation() {
        let symbolName = sleepPreventionEnabled ? "moon.fill" : "moon.zzz"
        statusItem.button?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: sleepPreventionEnabled ? "Sleep prevention on" : "Sleep allowed"
        )
        statusItem.button?.toolTip = sleepPreventionEnabled ? "Sleep Switch: sleep prevention on" : "Sleep Switch: sleep allowed"
        stateItem.title = sleepPreventionEnabled ? "Sleep prevention is on" : "Sleep is allowed"
        toggleItem.title = sleepPreventionEnabled ? "Allow sleep" : "Prevent sleep"
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
