import Darwin
import Foundation

@main
struct SleepSwitchFanHelperMain {
    static func main() {
        guard geteuid() == 0 else {
            fputs("Sleep Switch fan helper must run as root.\n", stderr)
            exit(EXIT_FAILURE)
        }

        do {
            let backend = try FanHardwareController()
            let manager = FanLeaseManager(backend: backend)
            _ = manager.recoverOnStartup()

            let listener = NSXPCListener(
                machServiceName: FanHelperConstants.machServiceName
            )
            listener.setConnectionCodeSigningRequirement(
                FanHelperConstants.applicationCodeSigningRequirement
            )
            let delegate = FanHelperListenerDelegate(manager: manager)
            listener.delegate = delegate
            let watchdog = FanLeaseWatchdog(manager: manager)

            let powerObserver = try SystemPowerObserver(
                willSleep: manager.systemWillSleep,
                didWake: manager.systemDidWake
            )

            let terminationSources = [
                makeTerminationSource(signal: SIGTERM, manager: manager),
                makeTerminationSource(signal: SIGINT, manager: manager)
            ]

            listener.activate()
            withExtendedLifetime(
                (
                    delegate,
                    watchdog,
                    terminationSources,
                    powerObserver
                )
            ) {
                RunLoop.current.run()
            }
        } catch {
            fputs("Sleep Switch fan helper could not start.\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func makeTerminationSource(
        signal signalNumber: Int32,
        manager: FanLeaseManager
    ) -> DispatchSourceSignal {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(
            signal: signalNumber,
            queue: .main
        )
        source.setEventHandler {
            manager.shutDown()
            exit(EXIT_SUCCESS)
        }
        source.resume()
        return source
    }
}
