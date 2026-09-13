import Darwin
import Foundation

enum PowerBackendError: Error, LocalizedError {
    case command, timeout, verification, journal
    var errorDescription: String? {
        switch self {
        case .command: return "macOS could not change the sleep setting."
        case .timeout: return "macOS took too long to respond to the power helper."
        case .verification: return "The power helper could not verify the macOS sleep setting."
        case .journal: return "The power helper could not save its sleep recovery record."
        }
    }
}

struct SystemSleepBackend: SystemSleepControlling {
    func sleepDisabled() throws -> Bool {
        guard let disabled = Self.parseSleepDisabled(try run(["-g"])) else {
            throw PowerBackendError.verification
        }
        return disabled
    }

    func setSleepDisabled(_ disabled: Bool) throws {
        _ = try run(["disablesleep", disabled ? "1" : "0"])
    }

    static func parseSleepDisabled(_ output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.first == "SleepDisabled", fields.count == 2 else { continue }
            if fields[1] == "0" { return false }
            if fields[1] == "1" { return true }
        }
        return nil
    }

    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + 2) == .success else {
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) != .success {
                kill(process.processIdentifier, SIGKILL)
            }
            throw PowerBackendError.timeout
        }
        guard process.terminationStatus == 0 else { throw PowerBackendError.command }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

/// The app never supplies this path. Only root may create or change the record.
final class PowerRecoveryJournal: PowerRecoveryJournaling {
    private let directory = "/var/db/lt.mantas.sleepswitch.powerhelper"
    private var path: String { directory + "/restore-sleep" }

    private func validateDirectory() throws {
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw PowerBackendError.journal }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 == 0 else {
            throw PowerBackendError.journal
        }
    }

    func needsRecovery() throws -> Bool {
        try validateDirectory()
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return false }
            throw PowerBackendError.journal
        }
        defer { close(descriptor) }
        try validate(descriptor)
        return true
    }

    func markPending() throws {
        try validateDirectory()
        let descriptor = open(path, O_WRONLY | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw PowerBackendError.journal }
        defer { close(descriptor) }
        try validate(descriptor)
        guard fsync(descriptor) == 0 else { throw PowerBackendError.journal }
        try syncDirectory()
    }

    func clear() throws {
        try validateDirectory()
        if unlink(path) != 0 && errno != ENOENT { throw PowerBackendError.journal }
        try syncDirectory()
    }

    private func validate(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o022 == 0,
              info.st_nlink == 1 else { throw PowerBackendError.journal }
    }

    private func syncDirectory() throws {
        let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw PowerBackendError.journal }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw PowerBackendError.journal }
    }
}
