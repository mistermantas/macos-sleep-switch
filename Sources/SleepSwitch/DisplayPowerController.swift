import Foundation
import IOKit.pwr_mgt

enum DisplayPowerError: Error, LocalizedError {
    case couldNotLaunch(Error)
    case sleepCommandFailed(Int32, String)
    case wakeFailed(IOReturn)

    var errorDescription: String? {
        switch self {
        case .couldNotLaunch(let error):
            return "macOS could not put the display to sleep. \(error.localizedDescription)"
        case .sleepCommandFailed(let status, let message):
            let detail = message.isEmpty ? "" : " \(message)"
            return "macOS could not put the display to sleep (status \(status)).\(detail)"
        case .wakeFailed(let code):
            return "macOS could not wake the display (error \(code))."
        }
    }
}

final class DisplayPowerController {
    static let sleepCommand = URL(fileURLWithPath: "/usr/bin/pmset")
    static let sleepArguments = ["displaysleepnow"]

    private var userActivityAssertionID = IOPMAssertionID()

    func sleepDisplay() throws {
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
