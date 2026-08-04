#if !APP_STORE
import AppKit

@MainActor
final class CoolingHelperMaintenance: NSObject, NSApplicationDelegate {
    static let refreshArgument = "--refresh-cooling-helper"

    private let client = FanHelperClient()
    private(set) var exitCode = 1

    func applicationDidFinishLaunching(_ notification: Notification) {
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
