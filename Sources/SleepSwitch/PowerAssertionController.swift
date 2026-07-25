import Foundation
import IOKit.pwr_mgt

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
