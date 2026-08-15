import Foundation
import IOKit.pwr_mgt

enum KeepAwakeMode: String, CaseIterable {
    case preventSleep
    case lidClosed

    var menuTitle: String {
        switch self {
        case .preventSleep:
            return "Prevent Sleep"
        case .lidClosed:
            return "Prevent Sleep Even With Lid Closed"
        }
    }

    var shortTitle: String {
        switch self {
        case .preventSleep:
            return "Prevent Sleep"
        case .lidClosed:
            return "Lid Closed"
        }
    }

    var stateTitle: String {
        switch self {
        case .preventSleep:
            return "Lid open"
        case .lidClosed:
            return "Lid closed"
        }
    }

    var toolTip: String {
        switch self {
        case .preventSleep:
            return "Keeps the Mac and display awake during active sessions. Closing the lid still sleeps normally."
        case .lidClosed:
            return "Prevents sleep even after the lid closes. Administrator approval is required when this mode becomes active."
        }
    }

    static func persistedMode(from rawValue: String?) -> KeepAwakeMode {
        if rawValue == "caffeine" {
            return .preventSleep
        }
        return KeepAwakeMode(rawValue: rawValue ?? "") ?? .preventSleep
    }
}

enum PowerAssertionError: Error, LocalizedError {
    case systemAssertion(IOReturn)
    case displayAssertion(IOReturn)

    var errorDescription: String? {
        switch self {
        case .systemAssertion(let code):
            return "macOS could not create the keep-awake assertion (error \(code))."
        case .displayAssertion(let code):
            return "macOS could not create the display assertion (error \(code))."
        }
    }
}

final class PowerAssertionController {
    private var systemAssertionID: IOPMAssertionID?
    private var displayAssertionID: IOPMAssertionID?

    var isActive: Bool {
        systemAssertionID != nil
    }

    var isKeepingDisplayAwake: Bool {
        displayAssertionID != nil
    }

    func start(keepDisplayAwake: Bool) throws {
        stop()

        var newSystemAssertionID = IOPMAssertionID()
        let systemResult = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Sleep Switch is keeping this Mac awake" as CFString,
            &newSystemAssertionID
        )

        guard systemResult == kIOReturnSuccess else {
            throw PowerAssertionError.systemAssertion(systemResult)
        }
        systemAssertionID = newSystemAssertionID

        guard keepDisplayAwake else { return }

        var newDisplayAssertionID = IOPMAssertionID()
        let displayResult = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Sleep Switch is keeping the display awake" as CFString,
            &newDisplayAssertionID
        )

        guard displayResult == kIOReturnSuccess else {
            stop()
            throw PowerAssertionError.displayAssertion(displayResult)
        }
        displayAssertionID = newDisplayAssertionID
    }

    func stop() {
        if let displayAssertionID {
            IOPMAssertionRelease(displayAssertionID)
            self.displayAssertionID = nil
        }

        if let systemAssertionID {
            IOPMAssertionRelease(systemAssertionID)
            self.systemAssertionID = nil
        }
    }

    deinit {
        stop()
    }
}

enum LidClosedSleepError: Error, LocalizedError {
    case unavailable
    case authorizationCancelled
    case commandLaunch(Error)
    case commandFailed(Int32, String)
    case stateUnavailable
    case stateChangeTimedOut(Bool)
    case markerCreationFailed
    case restorationInProgress

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Lid-closed mode is not available in this version of Sleep Switch."
        case .authorizationCancelled:
            return "Lid-closed mode needs administrator approval."
        case .commandLaunch(let error):
            return "Sleep Switch could not open the administrator approval prompt. \(error.localizedDescription)"
        case .commandFailed:
            return "Sleep Switch couldn’t enable lid-closed mode."
        case .stateUnavailable:
            return "Sleep Switch could not read the current macOS sleep state."
        case .stateChangeTimedOut(let disabled):
            let target = disabled ? "disable" : "restore"
            return "macOS did not \(target) sleep in time."
        case .markerCreationFailed:
            return "Sleep Switch could not prepare lid-closed mode."
        case .restorationInProgress:
            return "macOS is still restoring normal sleep."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .authorizationCancelled:
            return "Sleep Switch kept your previous awake mode."
        case .commandFailed:
            return "Normal sleep remains enabled. Try again, or quit and reopen Sleep Switch if this keeps happening."
        case .stateChangeTimedOut(let disabled):
#if APP_STORE
            _ = disabled
            return nil
#else
            if disabled {
                return "Sleep Switch stopped the attempt and asked macOS to restore normal sleep."
            }
            return "Run “sudo pmset disablesleep 0” in Terminal to restore normal sleep."
#endif
        case .restorationInProgress:
            return "Wait a moment before enabling lid-closed mode again."
        case .unavailable, .commandLaunch, .stateUnavailable, .markerCreationFailed:
            return nil
        }
    }
}

#if APP_STORE
final class LidClosedSleepController {
    var isActive: Bool { false }
    var isRestoring: Bool { false }
    var onRestorationFailure: ((Error) -> Void)?
    var onRestorationFinished: (() -> Void)?

    func start() throws {
        throw LidClosedSleepError.unavailable
    }

    func stop(waitForRestoration: Bool = true) throws {}
}
#else
final class LidClosedSleepController {
    static let pmsetPath = "/usr/bin/pmset"
    static let osascriptPath = "/usr/bin/osascript"
    static let heartbeatIntervalSeconds: TimeInterval = 2
    static let heartbeatStaleSeconds = 15
    static let watcherLabelPrefix =
        "lt.mantas.sleepswitch.lidwatcher"

    private(set) var isActive = false
    private(set) var ownsSystemSetting = false
    private(set) var isRestoring = false
    var onRestorationFailure: ((Error) -> Void)?
    var onRestorationFinished: (() -> Void)?

    private let markerDirectory: URL
    private let readSleepDisabled: () throws -> Bool
    private let waitForSleepDisabled: (Bool) -> Bool
    private let runAdministratorCommand: (String) throws -> Void
    private var markerURL: URL?
    private var restorationFailed = false
    private var restorationAttemptID: UUID?
    private let heartbeatQueue = DispatchQueue(
        label: "lt.mantas.sleepswitch.lid-heartbeat",
        qos: .utility
    )
    private let restorationQueue = DispatchQueue(
        label: "lt.mantas.sleepswitch.lid-restoration",
        qos: .userInitiated
    )
    private var heartbeatTimer: DispatchSourceTimer?

    init(
        markerDirectory: URL = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        ),
        readSleepDisabled: @escaping () throws -> Bool = {
            try LidClosedSleepController.readSystemSleepDisabled()
        },
        waitForSleepDisabled: @escaping (Bool) -> Bool = {
            LidClosedSleepController.waitForSystemSleepDisabled($0)
        },
        runAdministratorCommand: @escaping (String) throws -> Void = {
            try LidClosedSleepController.runWithAdministratorPrivileges($0)
        }
    ) {
        self.markerDirectory = markerDirectory
        self.readSleepDisabled = readSleepDisabled
        self.waitForSleepDisabled = waitForSleepDisabled
        self.runAdministratorCommand = runAdministratorCommand
    }

    func start() throws {
        guard !isActive else { return }
        guard !isRestoring, !restorationFailed else {
            throw LidClosedSleepError.restorationInProgress
        }

        if try readSleepDisabled() {
            isActive = true
            ownsSystemSetting = false
            return
        }

        let markerURL = markerDirectory
            .appendingPathComponent("lt.mantas.sleepswitch-lid-\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: markerURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw LidClosedSleepError.markerCreationFailed
        }

        self.markerURL = markerURL
        startHeartbeat(for: markerURL)
        let watcherLabel = Self.makeWatcherLabel()

        do {
            try runAdministratorCommand(
                Self.enableCommand(
                    markerURL: markerURL,
                    watcherLabel: watcherLabel
                )
            )
            guard waitForSleepDisabled(true) else {
                throw LidClosedSleepError.stateChangeTimedOut(true)
            }
        } catch {
            try? FileManager.default.removeItem(at: markerURL)
            clearState()
            _ = waitForSleepDisabled(false)
            throw error
        }

        ownsSystemSetting = true
        isActive = true
    }

    func stop(waitForRestoration: Bool = true) throws {
        guard isActive else {
            guard isRestoring || restorationFailed else { return }
            if waitForRestoration {
                try verifyRestoration()
            } else if !isRestoring {
                verifyRestorationWithoutBlocking()
            }
            return
        }

        guard ownsSystemSetting, let markerURL else {
            clearState()
            return
        }

        if FileManager.default.fileExists(atPath: markerURL.path) {
            try FileManager.default.removeItem(at: markerURL)
        }
        stopHeartbeat()

        self.markerURL = nil
        ownsSystemSetting = false
        isActive = false

        if waitForRestoration {
            try verifyRestoration()
        } else {
            verifyRestorationWithoutBlocking()
        }
    }

    static func sleepDisabled(from output: String) -> Bool? {
        guard let line = output
            .split(separator: "\n")
            .first(where: { $0.contains("SleepDisabled") })
        else {
            return nil
        }

        guard let value = line.split(whereSeparator: \.isWhitespace).last else {
            return nil
        }
        switch value {
        case "0":
            return false
        case "1":
            return true
        default:
            return nil
        }
    }

    static func enableCommand(
        markerURL: URL,
        watcherLabel: String
    ) -> String {
        let marker = shellQuote(markerURL.path)
        let label = shellQuote(watcherLabel)
        let serviceTarget = shellQuote("system/\(watcherLabel)")
        let watcher = restoreWatcherCommand(
            markerURL: markerURL,
            watcherLabel: watcherLabel
        )
        let cleanupAfterLaunchFailure =
            "status=$?; "
            + "/bin/rm -f \(marker); "
            + "if \(pmsetPath) disablesleep 0 >/dev/null 2>&1; then "
            + "/bin/launchctl remove \(label) >/dev/null 2>&1 || true; "
            + "fi; "
            + "exit $status"

        return "/bin/launchctl submit -l \(label) -- "
            + "/bin/sh -c \(shellQuote(watcher)) "
            + "|| { /bin/rm -f \(marker); exit 1; }; "
            + "/bin/launchctl print \(serviceTarget) >/dev/null 2>&1 "
            + "|| { \(cleanupAfterLaunchFailure); }; "
            + "\(pmsetPath) disablesleep 1 "
            + "|| { \(cleanupAfterLaunchFailure); }"
    }

    static func restoreWatcherCommand(
        markerURL: URL,
        watcherLabel: String
    ) -> String {
        let marker = shellQuote(markerURL.path)
        let label = shellQuote(watcherLabel)
        return
            "while /bin/test -e \(marker); do "
            + "modified=$(/usr/bin/stat -f %m \(marker) 2>/dev/null) "
            + "|| break; "
            + "now=$(/bin/date +%s); "
            + "if /bin/test $((now - modified)) -gt \(heartbeatStaleSeconds); "
            + "then break; fi; "
            + "/bin/sleep \(Int(heartbeatIntervalSeconds)); "
            + "done; "
            + "while ! { "
            + "\(pmsetPath) disablesleep 0 >/dev/null 2>&1 "
            + "&& \(pmsetPath) -g "
            + "| /usr/bin/awk "
            + shellQuote(
                "$1 == \"SleepDisabled\" && $2 == \"0\" "
                    + "{ restored = 1 } "
                    + "END { exit restored ? 0 : 1 }"
            )
            + "; }; do "
            + "/bin/sleep \(Int(heartbeatIntervalSeconds)); "
            + "done; "
            + "/bin/rm -f \(marker); "
            + "/bin/launchctl remove \(label) >/dev/null 2>&1; "
            + "exit 0"
    }

    deinit {
        stopHeartbeat()
        if let markerURL {
            try? FileManager.default.removeItem(at: markerURL)
        }
    }

    private func clearState() {
        stopHeartbeat()
        markerURL = nil
        ownsSystemSetting = false
        isActive = false
        isRestoring = false
        restorationFailed = false
        restorationAttemptID = nil
    }

    private static func makeWatcherLabel() -> String {
        "\(watcherLabelPrefix).\(UUID().uuidString.lowercased())"
    }

    private func startHeartbeat(for markerURL: URL) {
        stopHeartbeat()

        let markerPath = markerURL.path
        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        timer.schedule(
            deadline: .now(),
            repeating: Self.heartbeatIntervalSeconds
        )
        timer.setEventHandler {
            try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: markerPath
            )
        }
        heartbeatTimer = timer
        timer.resume()
    }

    private func stopHeartbeat() {
        heartbeatTimer?.setEventHandler {}
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    private func verifyRestoration() throws {
        restorationAttemptID = nil
        isRestoring = false
        guard waitForSleepDisabled(false) else {
            restorationFailed = true
            throw LidClosedSleepError.stateChangeTimedOut(false)
        }
        restorationFailed = false
    }

    private func verifyRestorationWithoutBlocking() {
        guard !isRestoring else { return }
        let attemptID = UUID()
        restorationAttemptID = attemptID
        isRestoring = true
        restorationFailed = false
        let waitForSleepDisabled = waitForSleepDisabled

        restorationQueue.async { [weak self] in
            let restored = waitForSleepDisabled(false)
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.restorationAttemptID == attemptID
                else {
                    return
                }
                self.restorationAttemptID = nil
                self.isRestoring = false
                self.restorationFailed = !restored
                self.onRestorationFinished?()
                if !restored {
                    self.onRestorationFailure?(
                        LidClosedSleepError.stateChangeTimedOut(false)
                    )
                }
            }
        }
    }

    private static func readSystemSleepDisabled() throws -> Bool {
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: pmsetPath)
        process.arguments = ["-g"]
        process.standardOutput = output
        process.standardError = errorOutput

        do {
            try process.run()
        } catch {
            throw LidClosedSleepError.commandLaunch(error)
        }

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw LidClosedSleepError.commandFailed(
                process.terminationStatus,
                message
            )
        }

        let text = String(data: outputData, encoding: .utf8) ?? ""
        guard let disabled = sleepDisabled(from: text) else {
            throw LidClosedSleepError.stateUnavailable
        }
        return disabled
    }

    private static func waitForSystemSleepDisabled(_ expected: Bool) -> Bool {
        for _ in 0..<40 {
            if (try? readSystemSleepDisabled()) == expected {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func runWithAdministratorPrivileges(_ command: String) throws {
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escapedCommand)\" with administrator privileges"

        let process = Process()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: osascriptPath)
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorOutput

        do {
            try process.run()
        } catch {
            throw LidClosedSleepError.commandLaunch(error)
        }

        let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if message.localizedCaseInsensitiveContains("User canceled") {
                throw LidClosedSleepError.authorizationCancelled
            }
            throw LidClosedSleepError.commandFailed(
                process.terminationStatus,
                message
            )
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
#endif
