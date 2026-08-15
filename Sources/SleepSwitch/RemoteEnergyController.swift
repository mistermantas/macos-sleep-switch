import Foundation
import IOKit
import IOKit.pwr_mgt

enum RemoteEnergyError: Error, LocalizedError {
    case unavailable(String)
    case commandFailed(String)
    case powerManagement(IOReturn)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message), .commandFailed(let message):
            return message
        case .powerManagement(let code):
            return "macOS rejected the power request (error \(code))."
        }
    }
}

/// The remote layer deliberately exposes only small, named actions. It never
/// accepts arbitrary shell commands from iOS. The direct-download build can
/// use the same local tools as its existing menu, while the sandboxed Mac App
/// Store build stays limited to public IOKit actions.
struct RemoteEnergyController {
#if !APP_STORE
    static let sleepCommand = "/usr/bin/pmset"
    static let sleepArguments = ["sleepnow"]
#endif

    static var capabilities: CompanionMacCapabilities {
#if APP_STORE
        return CompanionMacCapabilities(
            canSleepMac: true,
            canSleepDisplay: false,
            canWakeDisplay: true,
            canLockMac: false,
            canRestartMac: false,
            canShutdownMac: false,
            canSetKeepAwake: true,
            canSleepDisplayUntilAgentsFinish: false,
            supportsCloudKit: true,
            canControlManualSession: true,
            canSetCoolingProfile: false,
            canPreventSleepWithLidClosed: false
        )
#else
        return CompanionMacCapabilities(
            canSleepMac: true,
            canSleepDisplay: true,
            canWakeDisplay: true,
            canLockMac: canRun(CGSession.command),
            canRestartMac: canRun("/sbin/shutdown"),
            canShutdownMac: canRun("/sbin/shutdown"),
            canSetKeepAwake: true,
            canSleepDisplayUntilAgentsFinish: true,
            supportsCloudKit: true,
            canControlManualSession: true,
            canSetCoolingProfile: true,
            canPreventSleepWithLidClosed: true
        )
#endif
    }

    static func sleepMac() throws {
        let connection = IOPMFindPowerManagement(kIOMainPortDefault)
        guard connection != 0 else {
            throw RemoteEnergyError.unavailable("macOS did not expose its power-management service.")
        }
        defer { IOServiceClose(connection) }

        let result = IOPMSleepSystem(connection)
        guard result == kIOReturnSuccess else {
#if !APP_STORE
            if result == kIOReturnNotPermitted || result == kIOReturnNotPrivileged {
                try run(
                    executable: sleepCommand,
                    arguments: sleepArguments,
                    failureMessage: "macOS could not enter sleep."
                )
                return
            }
#endif
            throw RemoteEnergyError.powerManagement(result)
        }
    }

    static func wakeDisplay(using controller: DisplayPowerController) throws {
        try controller.wakeDisplay()
    }

#if !APP_STORE
    static func sleepDisplay(using controller: DisplayPowerController) throws {
        try controller.sleepDisplay()
    }

    static func lockMac() throws {
        try run(
            executable: CGSession.command,
            arguments: CGSession.arguments,
            failureMessage: "macOS could not lock the current user session."
        )
    }

    static func restartMac() throws {
        try run(
            executable: "/sbin/shutdown",
            arguments: ["-r", "now"],
            failureMessage: "macOS could not start a restart request."
        )
    }

    static func shutdownMac() throws {
        try run(
            executable: "/sbin/shutdown",
            arguments: ["-h", "now"],
            failureMessage: "macOS could not start a shutdown request."
        )
    }

    private static func run(
        executable: String,
        arguments: [String],
        failureMessage: String
    ) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw RemoteEnergyError.commandFailed(
                "\(failureMessage) \(error.localizedDescription)"
            )
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw RemoteEnergyError.commandFailed(
                detail.isEmpty ? failureMessage : "\(failureMessage) \(detail)"
            )
        }
    }
#endif

    private static func canRun(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

#if !APP_STORE
private enum CGSession {
    static let command = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
    static let arguments = ["-suspend"]
}
#endif
