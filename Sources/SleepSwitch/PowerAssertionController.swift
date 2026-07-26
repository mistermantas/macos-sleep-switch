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
            return "Prevents idle sleep. Closing the lid still sleeps normally."
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

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Lid-closed mode is not available in this version of Sleep Switch."
        case .authorizationCancelled:
            return "Lid-closed mode needs administrator approval."
        case .commandLaunch(let error):
            return "Sleep Switch could not open the administrator approval prompt. \(error.localizedDescription)"
        case .commandFailed(let status, let message):
            let detail = message.isEmpty ? "" : " \(message)"
            return "macOS could not change lid-closed sleep mode (status \(status)).\(detail)"
        case .stateUnavailable:
            return "Sleep Switch could not read the current macOS sleep state."
        case .stateChangeTimedOut(let disabled):
            let target = disabled ? "disable" : "restore"
            return "macOS did not \(target) sleep in time."
        case .markerCreationFailed:
            return "Sleep Switch could not prepare lid-closed mode."
        }
    }
}

#if APP_STORE
final class LidClosedSleepController {
    var isActive: Bool { false }

    func start() throws {
        throw LidClosedSleepError.unavailable
    }

    func stop() throws {}
}
#else
final class LidClosedSleepController {
    static let pmsetPath = "/usr/bin/pmset"
    static let osascriptPath = "/usr/bin/osascript"

    private(set) var isActive = false
    private(set) var ownsSystemSetting = false

    private let processIdentifier: Int32
    private let markerDirectory: URL
    private var markerURL: URL?

    init(
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        markerDirectory: URL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
    ) {
        self.processIdentifier = processIdentifier
        self.markerDirectory = markerDirectory
    }

    func start() throws {
        guard !isActive else { return }

        if try Self.readSystemSleepDisabled() {
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

        do {
            try Self.runWithAdministratorPrivileges(
                Self.enableCommand(
                    markerURL: markerURL,
                    processIdentifier: processIdentifier
                )
            )
            guard Self.waitForSystemSleepDisabled(true) else {
                throw LidClosedSleepError.stateChangeTimedOut(true)
            }
        } catch {
            try? FileManager.default.removeItem(at: markerURL)
            throw error
        }

        self.markerURL = markerURL
        ownsSystemSetting = true
        isActive = true
    }

    func stop() throws {
        guard isActive else { return }

        guard ownsSystemSetting, let markerURL else {
            clearState()
            return
        }

        if FileManager.default.fileExists(atPath: markerURL.path) {
            try FileManager.default.removeItem(at: markerURL)
        }

        guard Self.waitForSystemSleepDisabled(false) else {
            throw LidClosedSleepError.stateChangeTimedOut(false)
        }
        clearState()
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
        processIdentifier: Int32
    ) -> String {
        let marker = shellQuote(markerURL.path)
        let watcher =
            "while /bin/kill -0 \(processIdentifier) 2>/dev/null "
            + "&& /bin/test -e \(marker); "
            + "do /bin/sleep 1; done; "
            + "\(pmsetPath) disablesleep 0; "
            + "/bin/rm -f \(marker)"

        return "/usr/bin/nohup /bin/sh -c \(shellQuote(watcher)) "
            + "</dev/null >/dev/null 2>&1 & "
            + "watcher_pid=$!; "
            + "/bin/kill -0 \"$watcher_pid\" 2>/dev/null || exit 1; "
            + "\(pmsetPath) disablesleep 1 || { "
            + "status=$?; /bin/rm -f \(marker); exit $status; }"
    }

    deinit {
        if let markerURL {
            try? FileManager.default.removeItem(at: markerURL)
        }
    }

    private func clearState() {
        markerURL = nil
        ownsSystemSetting = false
        isActive = false
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
