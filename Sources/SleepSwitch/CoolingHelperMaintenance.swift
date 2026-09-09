#if !APP_STORE
import AppKit
import ServiceManagement

@MainActor
final class CoolingHelperMaintenance: NSObject, NSApplicationDelegate {
    static let refreshArgument = "--refresh-cooling-helper"
    static let diagnosticsArgument = "--cooling-diagnostics"
    static let removeArgument = "--remove-cooling-helper"
    static let loginArgument = "--refresh-login-item"
    static let arguments = [refreshArgument, diagnosticsArgument, removeArgument, loginArgument]

    private let client = FanHelperClient()
    private(set) var exitCode = 1

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.finish(code: 6, message: "Cooling helper did not respond within 20 seconds.")
        }
        if CommandLine.arguments.contains(Self.loginArgument) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
                try SMAppService.mainApp.register()
                let enabled = SMAppService.mainApp.status == .enabled
                finish(code: enabled ? 0 : 2, message: enabled
                    ? "Launch at login now uses \(Bundle.main.bundleURL.path)."
                    : "Launch at login needs approval in System Settings."
                )
            } catch {
                finish(code: 5, message: "Could not refresh launch at login: \(error.localizedDescription)")
            }
            return
        }
        if CommandLine.arguments.contains(Self.diagnosticsArgument) {
            client.status { [weak self] response in
                guard let self else { return }
                let presentation = CoolingPresentationSnapshot(
                    selectedProfile: .systemControl, registrationState: self.client.registrationState,
                    helperSnapshot: response.snapshot, message: response.message,
                    controlEnabled: false, hasActiveLease: false
                )
                self.finish(code: response.succeeded ? 0 : 1, message:
                    CoolingDiagnosticReport.text(presentation: presentation, thermalLevel: ProcessInfoThermalMonitor().currentLevel)
                    + (presentation.failureReason.map { "Problem: \($0)\n\(presentation.recoverySuggestion)" } ?? "")
                )
            }
            return
        }
        if CommandLine.arguments.contains(Self.removeArgument) {
            client.unregister { [weak self] error in
                self?.finish(code: error == nil ? 0 : 4, message:
                    error.map { "Could not remove cooling helper: \($0.localizedDescription)" }
                    ?? "System fan control restored; cooling helper removed."
                )
            }
            return
        }
        switch client.registrationState {
        case .enabled:
            refreshRegisteredHelper()
        case .notRegistered, .notFound:
            registerCurrentHelper()
        case .requiresApproval:
            finish(
                code: 2,
                message: "Cooling helper still needs approval in System Settings."
            )
        case .requiresSignedBuild:
            finish(
                code: 3,
                message: "Cooling helper refresh requires a signed direct build."
            )
        }
    }

    private func refreshRegisteredHelper() {
        client.unregister { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(
                    code: 4,
                    message: "Could not unregister the previous cooling helper: \(error)"
                )
                return
            }

            // Service Management can reject an immediate re-registration even
            // after its unregister completion handler has fired.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.registerCurrentHelper()
            }
        }
    }

    private func registerCurrentHelper() {
        do {
            try client.register()
            switch client.registrationState {
            case .enabled:
                finish(code: 0, message: "Cooling helper refreshed.")
            case .requiresApproval:
                finish(
                    code: 2,
                    message: "Cooling helper needs approval in System Settings."
                )
            default:
                finish(
                    code: 5,
                    message: "Cooling helper did not become available."
                )
            }
        } catch {
            finish(
                code: 5,
                message: "Could not register the cooling helper: \(error)"
            )
        }
    }

    private func finish(code: Int, message: String) {
        exitCode = code
        FileHandle.standardOutput.write(Data("\(message)\n".utf8))
        NSApp.terminate(nil)
    }
}
#endif
