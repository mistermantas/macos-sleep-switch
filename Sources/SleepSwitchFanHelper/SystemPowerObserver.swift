import Foundation
import IOKit
import IOKit.pwr_mgt

enum SystemPowerObserverError: Error {
    case registrationFailed
}

enum SystemPowerEvent: Equatable {
    case allowIdleSleep
    case willSleep
    case didWake
    case ignore
}

final class SystemPowerObserver {
    // Swift cannot import the iokit_common_msg(...) macros in IOMessage.h.
    static let canSystemSleepMessage: UInt32 = 0xe000_0270
    static let systemWillSleepMessage: UInt32 = 0xe000_0280
    static let systemHasPoweredOnMessage: UInt32 = 0xe000_0300

    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var notificationPort: IONotificationPortRef?
    private let notificationQueue = DispatchQueue(
        label: "lt.mantas.sleepswitch.fanhelper.power",
        qos: .userInitiated
    )
    private let willSleep: () -> Void
    private let didWake: () -> Void

    init(
        willSleep: @escaping () -> Void,
        didWake: @escaping () -> Void
    ) throws {
        self.willSleep = willSleep
        self.didWake = didWake

        var port: IONotificationPortRef?
        var notifier: io_object_t = 0
        let rootPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(),
            &port,
            systemPowerCallback,
            &notifier
        )
        guard rootPort != IO_OBJECT_NULL, let port else {
            throw SystemPowerObserverError.registrationFailed
        }

        self.rootPort = rootPort
        self.notifier = notifier
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, notificationQueue)
    }

    deinit {
        guard let notificationPort else { return }
        IONotificationPortSetDispatchQueue(notificationPort, nil)
        _ = IODeregisterForSystemPower(&notifier)
        IONotificationPortDestroy(notificationPort)
        _ = IOServiceClose(rootPort)
    }

    static func event(for messageType: UInt32) -> SystemPowerEvent {
        switch messageType {
        case canSystemSleepMessage:
            return .allowIdleSleep
        case systemWillSleepMessage:
            return .willSleep
        case systemHasPoweredOnMessage:
            return .didWake
        default:
            return .ignore
        }
    }

    fileprivate func handle(
        messageType: UInt32,
        messageArgument: UnsafeMutableRawPointer?
    ) {
        switch Self.event(for: messageType) {
        case .allowIdleSleep:
            allowPowerChange(messageArgument)
        case .willSleep:
            willSleep()
            allowPowerChange(messageArgument)
        case .didWake:
            didWake()
        case .ignore:
            break
        }
    }

    private func allowPowerChange(
        _ messageArgument: UnsafeMutableRawPointer?
    ) {
        _ = IOAllowPowerChange(
            rootPort,
            Int(bitPattern: messageArgument)
        )
    }
}

private func systemPowerCallback(
    refcon: UnsafeMutableRawPointer?,
    service: io_service_t,
    messageType: UInt32,
    messageArgument: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let observer = Unmanaged<SystemPowerObserver>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    observer.handle(
        messageType: messageType,
        messageArgument: messageArgument
    )
}
