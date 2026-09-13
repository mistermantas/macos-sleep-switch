import Foundation

protocol SystemSleepControlling {
    func sleepDisabled() throws -> Bool
    func setSleepDisabled(_ disabled: Bool) throws
}

protocol PowerRecoveryJournaling {
    func needsRecovery() throws -> Bool
    func markPending() throws
    func clear() throws
}

/// All state and backend calls are serialized, including disconnects and expiry.
final class PowerLeaseManager {
    private struct Lease {
        let connection: UUID
        let token: String
        var expires: TimeInterval
    }
    private let queue = DispatchQueue(label: "lt.mantas.sleepswitch.powerhelper.lease")
    private let backend: SystemSleepControlling
    private let journal: PowerRecoveryJournaling
    private let now: () -> TimeInterval
    private var lease: Lease?
    private var recoveryPending = false
    private var startupChecked = false
    private var failure: String?

    init(backend: SystemSleepControlling, journal: PowerRecoveryJournaling,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.backend = backend
        self.journal = journal
        self.now = now
    }

    @discardableResult func recoverOnStartup() -> PowerHelperReply {
        queue.sync {
            do {
                recoveryPending = try journal.needsRecovery()
                startupChecked = true
                try restoreIfNeeded()
                return PowerHelperReply(succeeded: true)
            } catch { return failed(error) }
        }
    }

    func status(connection: UUID) -> PowerHelperReply {
        queue.sync {
            PowerHelperReply(succeeded: startupChecked && failure == nil,
                token: lease?.connection == connection ? lease!.token : "",
                message: failure ?? (lease == nil ? "Ready" : "Lid-closed session active"))
        }
    }

    func begin(connection: UUID) -> PowerHelperReply {
        queue.sync {
            guard startupChecked else { return PowerHelperReply(succeeded: false, message: failure ?? "Power helper is recovering.") }
            do {
                expireIfNeeded()
                if let lease {
                    guard lease.connection == connection else {
                        return PowerHelperReply(succeeded: false, message: "Another Sleep Switch session is using lid-closed mode.")
                    }
                    return PowerHelperReply(succeeded: true, token: lease.token)
                }
                try restoreIfNeeded()
                if try !backend.sleepDisabled() {
                    // Commit recovery intent before changing the global setting.
                    try journal.markPending()
                    recoveryPending = true
                    do {
                        try backend.setSleepDisabled(true)
                        guard try backend.sleepDisabled() else { throw PowerBackendError.verification }
                    } catch {
                        try? restoreIfNeeded()
                        throw error
                    }
                }
                let newLease = Lease(connection: connection, token: UUID().uuidString,
                                     expires: now() + PowerHelperConstants.leaseDuration)
                lease = newLease
                failure = nil
                return PowerHelperReply(succeeded: true, token: newLease.token)
            } catch { return failed(error) }
        }
    }

    func renew(connection: UUID, token: String) -> PowerHelperReply {
        queue.sync {
            expireIfNeeded()
            guard var current = lease, current.connection == connection, current.token == token else {
                return PowerHelperReply(succeeded: false, message: "The lid-closed session ended. Normal sleep is being restored.")
            }
            current.expires = now() + PowerHelperConstants.leaseDuration
            lease = current
            return PowerHelperReply(succeeded: true, token: token)
        }
    }

    func end(connection: UUID, token: String) -> PowerHelperReply {
        queue.sync {
            if let current = lease {
                guard current.connection == connection, current.token == token else {
                    return PowerHelperReply(succeeded: false, message: "This connection does not own the lid-closed session.")
                }
                lease = nil
            }
            do { try restoreIfNeeded(); return PowerHelperReply(succeeded: true) }
            catch { return failed(error) }
        }
    }

    func connectionEnded(_ connection: UUID) {
        queue.sync {
            guard lease?.connection == connection else { return }
            lease = nil
            do { try restoreIfNeeded() } catch { _ = failed(error) }
        }
    }

    func tick() {
        queue.sync {
            expireIfNeeded()
            if lease == nil {
                do { try restoreIfNeeded() } catch { _ = failed(error) }
            }
        }
    }

    func restoreForSleepOrExit() {
        queue.sync {
            lease = nil
            do { try restoreIfNeeded() } catch { _ = failed(error) }
        }
    }

    private func expireIfNeeded() {
        guard let current = lease, now() >= current.expires else { return }
        lease = nil
        do { try restoreIfNeeded() } catch { _ = failed(error) }
    }

    private func restoreIfNeeded() throws {
        guard recoveryPending else { return }
        try backend.setSleepDisabled(false)
        guard try !backend.sleepDisabled() else { throw PowerBackendError.verification }
        try journal.clear()
        recoveryPending = false
        failure = nil
    }

    private func failed(_ error: Error) -> PowerHelperReply {
        failure = error.localizedDescription
        return PowerHelperReply(succeeded: false, message: error.localizedDescription)
    }
}
