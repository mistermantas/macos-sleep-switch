#if !APP_STORE
import AppKit
import ServiceManagement

@MainActor final class PowerHelperMaintenance: NSObject, NSApplicationDelegate {
    static let arguments = ["--setup-power-helper", "--power-helper-status"]
    private(set) var exitCode: Int32 = 1
    private let client = PowerHelperClient()

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            if CommandLine.arguments.contains("--setup-power-helper") { try client.register() }
            if client.isReady {
                // Status never begins or renews a power lease.
                finish(0, try client.status())
            } else { finish(2, client.setupMessage) }
        } catch { finish(1, error.localizedDescription) }
    }
    private func finish(_ code: Int32, _ message: String) {
        exitCode = code
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
        // NSApplication.terminate exits with zero, losing the diagnostic result.
        exit(code)
    }
}
#endif
