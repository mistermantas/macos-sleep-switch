import Foundation

final class FanLeaseWatchdog {
    private let timer: DispatchSourceTimer

    init(
        manager: FanLeaseManager,
        interval: TimeInterval = 1
    ) {
        let queue = DispatchQueue(
            label: "lt.mantas.sleepswitch.fanhelper.watchdog",
            qos: .utility
        )
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak manager] in
            manager?.expireIfNeeded()
        }
        timer.resume()
    }

    deinit {
        timer.setEventHandler {}
        timer.cancel()
    }
}
