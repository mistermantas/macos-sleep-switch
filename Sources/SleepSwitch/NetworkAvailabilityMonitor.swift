import Foundation
import Network

/// Observes only whether this Mac has a usable network path. It deliberately
/// never records or publishes an SSID, address, interface name, or network ID.
@MainActor
final class NetworkAvailabilityMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "lt.mantas.sleepswitch.network-path")
    private let onChange: () -> Void
    private(set) var status: CompanionNetworkStatus = .unknown
    private var isStarted = false

    init(onChange: @escaping () -> Void = {}) {
        self.onChange = onChange
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            let next = Self.status(for: path)
            Task { @MainActor [weak self] in
                guard let self, self.status != next else { return }
                self.status = next
                self.onChange()
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        monitor.cancel()
    }

    nonisolated static func status(for path: NWPath) -> CompanionNetworkStatus {
        switch path.status {
        case .satisfied:
            path.isConstrained || path.isExpensive ? .constrained : .online
        case .unsatisfied:
            .offline
        case .requiresConnection:
            .constrained
        @unknown default:
            .unknown
        }
    }
}
