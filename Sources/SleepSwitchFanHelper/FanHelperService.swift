import Foundation

final class FanHelperService: NSObject, FanHelperProtocol {
    private let connectionID: UUID
    private let manager: FanLeaseManager

    init(connectionID: UUID, manager: FanLeaseManager) {
        self.connectionID = connectionID
        self.manager = manager
    }

    func status(withReply reply: @escaping (FanHelperResponse) -> Void) {
        reply(manager.status(connectionID: connectionID))
    }

    func beginLease(
        profileRawValue: Int,
        withReply reply: @escaping (FanHelperResponse) -> Void
    ) {
        reply(
            manager.beginLease(
                connectionID: connectionID,
                profileRawValue: profileRawValue
            )
        )
    }

    func renewLease(
        _ leaseToken: UUID,
        coolingDemand: Double,
        withReply reply: @escaping (FanHelperResponse) -> Void
    ) {
        reply(
            manager.renewLease(
                connectionID: connectionID,
                leaseToken: leaseToken,
                coolingDemand: coolingDemand
            )
        )
    }

    func endLease(
        _ leaseToken: UUID,
        withReply reply: @escaping (FanHelperResponse) -> Void
    ) {
        reply(
            manager.endLease(
                connectionID: connectionID,
                leaseToken: leaseToken
            )
        )
    }

    func restoreSystemControl(
        withReply reply: @escaping (FanHelperResponse) -> Void
    ) {
        reply(manager.restoreSystemControl())
    }
}

final class FanHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let manager: FanLeaseManager
    private let validator: FanClientValidating
    private let connectionQueue = DispatchQueue(
        label: "lt.mantas.sleepswitch.fanhelper.connections"
    )
    private var connections: [UUID: NSXPCConnection] = [:]

    init(
        manager: FanLeaseManager,
        validator: FanClientValidating = FanClientValidator()
    ) {
        self.manager = manager
        self.validator = validator
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard validator.accepts(
            processIdentifier: newConnection.processIdentifier
        ) else {
            return false
        }

        let connectionID = UUID()
        let service = FanHelperService(
            connectionID: connectionID,
            manager: manager
        )
        newConnection.exportedInterface = FanHelperXPCInterface.make()
        newConnection.exportedObject = service

        let ended = { [weak self, weak newConnection] in
            self?.manager.connectionEnded(connectionID)
            self?.connectionQueue.async {
                self?.connections.removeValue(forKey: connectionID)
                newConnection?.invalidationHandler = nil
                newConnection?.interruptionHandler = nil
            }
        }
        newConnection.interruptionHandler = ended
        newConnection.invalidationHandler = ended

        connectionQueue.sync {
            connections[connectionID] = newConnection
        }
        newConnection.activate()
        return true
    }
}
