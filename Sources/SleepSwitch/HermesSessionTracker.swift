import Darwin
import Foundation

/// Reads Hermes' small runtime lease file rather than treating its persistent
/// gateway or CLI process as an active task. Hermes removes a lease when a
/// session ends; checking the recorded PID protects against stale leases left
/// behind by a crash.
struct HermesSessionTracker {
    let activeSessionsURL: URL
    let processIsRunning: (Int32) -> Bool

    init(
        activeSessionsURL: URL = HermesSessionTracker.defaultActiveSessionsURL,
        processIsRunning: @escaping (Int32) -> Bool = HermesSessionTracker.isProcessRunning
    ) {
        self.activeSessionsURL = activeSessionsURL
        self.processIsRunning = processIsRunning
    }

    func scan() -> Int? {
        guard let data = try? Data(contentsOf: activeSessionsURL),
              let file = try? JSONDecoder().decode(ActiveSessionsFile.self, from: data)
        else {
            return nil
        }

        return file.entries.reduce(into: 0) { count, entry in
            guard entry.trackLiveness ?? true,
                  let pid = entry.pid,
                  pid > 0,
                  processIsRunning(pid) else {
                return
            }
            count += 1
        }
    }

    private struct ActiveSessionsFile: Decodable {
        let entries: [ActiveSessionEntry]
    }

    private struct ActiveSessionEntry: Decodable {
        let pid: Int32?
        let trackLiveness: Bool?

        enum CodingKeys: String, CodingKey {
            case pid
            case trackLiveness = "track_liveness"
        }
    }

    private static var defaultActiveSessionsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/runtime/active_sessions.json")
    }

    private static func isProcessRunning(_ pid: Int32) -> Bool {
        guard kill(pid_t(pid), 0) != 0 else { return true }
        return errno == EPERM
    }
}
