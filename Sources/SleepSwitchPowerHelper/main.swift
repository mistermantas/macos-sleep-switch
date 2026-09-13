import Darwin
import Foundation

@main struct SleepSwitchPowerHelperMain {
    static func main() {
        guard geteuid() == 0 else { exit(EXIT_FAILURE) }
        let manager = PowerLeaseManager(backend: SystemSleepBackend(), journal: PowerRecoveryJournal())
        _ = manager.recoverOnStartup()
        let listener = NSXPCListener(machServiceName: PowerHelperConstants.identifier)
        listener.setConnectionCodeSigningRequirement(PowerHelperConstants.applicationRequirement)
        let delegate = PowerHelperListenerDelegate(manager: manager)
        listener.delegate = delegate
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + 1, repeating: 1)
        watchdog.setEventHandler { manager.tick() }
        watchdog.resume()
        do {
            let observer = try SystemPowerObserver(willSleep: manager.restoreForSleepOrExit, didWake: manager.tick)
            let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { manager.restoreForSleepOrExit(); exit(EXIT_SUCCESS) }
                source.resume()
                return source
            }
            listener.activate()
            withExtendedLifetime((delegate, observer, watchdog, signals)) { RunLoop.current.run() }
        } catch {
            manager.restoreForSleepOrExit()
            exit(EXIT_FAILURE)
        }
    }
}
