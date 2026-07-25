import Foundation
import IOKit.pwr_mgt

enum DisplayPowerError: Error, LocalizedError {
#if APP_STORE
    case displaySleepUnavailable
#else
    case couldNotLaunch(Error)
    case sleepCommandFailed(Int32, String)
#endif
    case wakeFailed(IOReturn)

    var errorDescription: String? {
        switch self {
#if APP_STORE
        case .displaySleepUnavailable:
            return "The Mac App Store build cannot put the display to sleep automatically."
#else
        case .couldNotLaunch(let error):
            return "macOS could not put the display to sleep. \(error.localizedDescription)"
        case .sleepCommandFailed(let status, let message):
            let detail = message.isEmpty ? "" : " \(message)"
            return "macOS could not put the display to sleep (status \(status)).\(detail)"
#endif
        case .wakeFailed(let code):
            return "macOS could not wake the display (error \(code))."
        }
    }
}

final class DisplayPowerController {
#if !APP_STORE
    static let sleepCommand = URL(fileURLWithPath: "/usr/bin/pmset")
    static let sleepArguments = ["displaysleepnow"]
#endif

    private var userActivityAssertionID = IOPMAssertionID()

    func sleepDisplay() throws {
#if APP_STORE
        throw DisplayPowerError.displaySleepUnavailable
#else
        let process = Process()
        let standardError = Pipe()
        process.executableURL = Self.sleepCommand
        process.arguments = Self.sleepArguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw DisplayPowerError.couldNotLaunch(error)
        }

        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw DisplayPowerError.sleepCommandFailed(process.terminationStatus, message)
        }
#endif
    }

    func wakeDisplay() throws {
        let result = IOPMAssertionDeclareUserActivity(
            "Sleep Switch: agent sessions finished" as CFString,
            kIOPMUserActiveLocal,
            &userActivityAssertionID
        )

        guard result == kIOReturnSuccess else {
            throw DisplayPowerError.wakeFailed(result)
        }
    }

    deinit {
        if userActivityAssertionID != 0 {
            IOPMAssertionRelease(userActivityAssertionID)
        }
    }
}
