import Foundation

final class PowerHelperService: NSObject, PowerHelperProtocol {
    let connectionID: UUID
    let manager: PowerLeaseManager
    init(connectionID: UUID, manager: PowerLeaseManager) {
        self.connectionID = connectionID
        self.manager = manager
    }
    private func send(_ result: PowerHelperReply, _ reply: (Bool, String, String) -> Void) {
        reply(result.succeeded, result.token, result.message)
    }
    func status(withReply reply: @escaping (Bool, String, String) -> Void) {
        send(manager.status(connection: connectionID), reply)
    }
    func beginLease(withReply reply: @escaping (Bool, String, String) -> Void) {
        send(manager.begin(connection: connectionID), reply)
    }
    func renewLease(_ token: String, withReply reply: @escaping (Bool, String, String) -> Void) {
        send(manager.renew(connection: connectionID, token: token), reply)
    }
    func endLease(_ token: String, withReply reply: @escaping (Bool, String, String) -> Void) {
        send(manager.end(connection: connectionID, token: token), reply)
    }
}

final class PowerHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let manager: PowerLeaseManager
    private let queue = DispatchQueue(label: "lt.mantas.sleepswitch.powerhelper.connections")
    private var connections: [UUID: NSXPCConnection] = [:]
    init(manager: PowerLeaseManager) { self.manager = manager }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard PowerClientValidator().accepts(processIdentifier: connection.processIdentifier) else { return false }
        let id = UUID()
        connection.setCodeSigningRequirement(PowerHelperConstants.applicationRequirement)
        connection.exportedInterface = NSXPCInterface(with: PowerHelperProtocol.self)
        connection.exportedObject = PowerHelperService(connectionID: id, manager: manager)
        let ended = { [weak self, weak connection] in
            self?.manager.connectionEnded(id)
            self?.queue.async { [weak self, weak connection] in
                self?.connections.removeValue(forKey: id)
                connection?.interruptionHandler = nil
                connection?.invalidationHandler = nil
                connection?.invalidate()
            }
        }
        connection.interruptionHandler = ended
        connection.invalidationHandler = ended
        queue.sync { connections[id] = connection }
        connection.activate()
        return true
    }
}
