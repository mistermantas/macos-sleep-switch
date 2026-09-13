import Foundation
import IOKit.pwr_mgt

enum KeepAwakeMode: String, CaseIterable {
    case preventSleep
    case lidClosed

    var menuTitle: String {
        switch self {
        case .preventSleep:
            return "Prevent Sleep"
        case .lidClosed:
            return "Prevent Sleep Even With Lid Closed"
        }
    }

    var shortTitle: String {
        switch self {
        case .preventSleep:
            return "Prevent Sleep"
        case .lidClosed:
            return "Lid Closed"
        }
    }

    var stateTitle: String {
        switch self {
        case .preventSleep:
            return "Lid open"
        case .lidClosed:
            return "Lid closed"
        }
    }

    var toolTip: String {
        switch self {
        case .preventSleep:
            return "Keeps the Mac and display awake during active sessions. Closing the lid still sleeps normally."
        case .lidClosed:
            return "Prevents sleep even after the lid closes. Administrator approval is needed once to set up the lid-closed helper."
        }
    }

    static func persistedMode(from rawValue: String?) -> KeepAwakeMode {
        if rawValue == "caffeine" {
            return .preventSleep
        }
        return KeepAwakeMode(rawValue: rawValue ?? "") ?? .preventSleep
    }
}

enum PowerAssertionError: Error, LocalizedError {
    case systemAssertion(IOReturn)
    case displayAssertion(IOReturn)

    var errorDescription: String? {
        switch self {
        case .systemAssertion(let code):
            return "macOS could not create the keep-awake assertion (error \(code))."
        case .displayAssertion(let code):
            return "macOS could not create the display assertion (error \(code))."
        }
    }
}

final class PowerAssertionController {
    private var systemAssertionID: IOPMAssertionID?
    private var displayAssertionID: IOPMAssertionID?

    var isActive: Bool {
        systemAssertionID != nil
    }

    var isKeepingDisplayAwake: Bool {
        displayAssertionID != nil
    }

    func start(keepDisplayAwake: Bool) throws {
        stop()

        var newSystemAssertionID = IOPMAssertionID()
        let systemResult = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Sleep Switch is keeping this Mac awake" as CFString,
            &newSystemAssertionID
        )

        guard systemResult == kIOReturnSuccess else {
            throw PowerAssertionError.systemAssertion(systemResult)
        }
        systemAssertionID = newSystemAssertionID

        guard keepDisplayAwake else { return }

        var newDisplayAssertionID = IOPMAssertionID()
        let displayResult = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Sleep Switch is keeping the display awake" as CFString,
            &newDisplayAssertionID
        )

        guard displayResult == kIOReturnSuccess else {
            stop()
            throw PowerAssertionError.displayAssertion(displayResult)
        }
        displayAssertionID = newDisplayAssertionID
    }

    func stop() {
        if let displayAssertionID {
            IOPMAssertionRelease(displayAssertionID)
            self.displayAssertionID = nil
        }

        if let systemAssertionID {
            IOPMAssertionRelease(systemAssertionID)
            self.systemAssertionID = nil
        }
    }

    deinit {
        stop()
    }
}

enum LidClosedSleepError: Error, LocalizedError {
    case unavailable
    case authorizationCancelled
    var errorDescription: String? { "Lid-closed mode is not available in this version of Sleep Switch." }
}

#if APP_STORE
final class LidClosedSleepController {
    var isActive: Bool { false }
    var isRestoring: Bool { false }
    var diagnosticReport: String { "Lid-closed mode is unavailable in the App Store build." }
    func start() throws { throw LidClosedSleepError.unavailable }
    func stop(waitForRestoration: Bool = true) throws {}
}
#else
/// UI state belongs to the main queue; XPC requests and heartbeats share one
/// worker queue. A stop queued during start always releases the returned lease.
final class LidClosedSleepController {
    private(set) var isActive = false
    private(set) var isStarting = false
    private(set) var isRestoring = false
    private(set) var issue: String?
    var onRestorationFailure: ((Error) -> Void)?
    var onRestorationFinished: (() -> Void)?
    var onStateChanged: (() -> Void)?
    private let client: PowerHelperConnecting
    private let worker = DispatchQueue(label: "lt.mantas.sleepswitch.power-client")
    private var generation = UUID()
    private var retryAfter = Date.distantPast
    // Accessed only on worker.
    private var token: String?
    private var timer: DispatchSourceTimer?

    init(client: PowerHelperConnecting = PowerHelperClient()) { self.client = client }
    var setupMessage: String? { client.isReady ? nil : client.setupMessage }
    var diagnosticReport: String {
        issue ?? setupMessage ?? (isActive ? "Lid-closed helper session active." : "Normal sleep restored.")
    }

    func retry() {
        retryAfter = .distantPast
        issue = nil
    }

    func start() throws {
        guard !isActive, !isStarting, !isRestoring else { return }
        guard client.isReady else {
            issue = client.setupMessage
            return
        }
        guard Date() >= retryAfter else { return }
        issue = nil
        isStarting = true
        let attempt = UUID()
        generation = attempt
        worker.async { [weak self] in
            guard let self else { return }
            do {
                self.token = try self.client.begin()
                self.startHeartbeat(attempt: attempt)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == attempt else { return }
                    self.isStarting = false
                    self.isActive = true
                    self.issue = nil
                    self.onStateChanged?()
                }
            } catch { self.reportFailure(error, attempt: attempt) }
        }
    }

    func stop(waitForRestoration: Bool = true) throws {
        guard isActive || isStarting || isRestoring else { return }
        let attempt = UUID()
        generation = attempt
        isActive = false
        isStarting = false
        isRestoring = true
        let restore = { [self] () -> Error? in
            timer?.cancel()
            timer = nil
            defer { token = nil; client.disconnect() }
            guard let token else { return nil }
            do { try client.end(token); return nil }
            catch { return error }
        }
        if waitForRestoration {
            let error = worker.sync(execute: restore)
            finishRestoring(error: error, attempt: attempt)
            if let error { throw error }
        } else {
            worker.async { [weak self] in
                let error = restore()
                DispatchQueue.main.async { [weak self] in
                    self?.finishRestoring(error: error, attempt: attempt)
                }
            }
        }
    }

    private func startHeartbeat(attempt: UUID) {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now() + PowerHelperConstants.heartbeatInterval,
                       repeating: PowerHelperConstants.heartbeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let token = self.token else { return }
            do { try self.client.renew(token) }
            catch {
                self.timer?.cancel()
                self.timer = nil
                self.token = nil
                self.client.disconnect()
                self.reportFailure(error, attempt: attempt)
            }
        }
        self.timer = timer
        timer.resume()
    }

    private func reportFailure(_ error: Error, attempt: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == attempt else { return }
            self.isStarting = false
            self.isActive = false
            self.issue = error.localizedDescription
            self.retryAfter = Date().addingTimeInterval(15)
            self.onStateChanged?()
        }
    }

    private func finishRestoring(error: Error?, attempt: UUID) {
        guard generation == attempt else { return }
        isRestoring = false
        issue = error?.localizedDescription
        if let error {
            retryAfter = Date().addingTimeInterval(15)
            onRestorationFailure?(error)
        } else { onRestorationFinished?() }
        onStateChanged?()
    }

    deinit { timer?.cancel(); client.disconnect() }
}
#endif
